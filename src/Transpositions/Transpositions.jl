module Transpositions

import LinearAlgebra: transpose!
export transpose!  # to avoid needing to import LinearAlgebra in user code

using TimerOutputs
import MPI
using GPUArrays
using KernelAbstractions
using KernelAbstractions: @index, @kernel
using CUDA
using ..PencilArrays
using ..PencilArrays: typeof_ptr, typeof_array
using ..Pencils: ArrayRegion
using StaticPermutations
using Strided: @strided, Strided, StridedView
using NVTX
# Declare transposition approaches.
abstract type AbstractTransposeMethod end

struct PointToPoint <: AbstractTransposeMethod end
struct Alltoallv <: AbstractTransposeMethod end

function Base.show(io::IO, ::T) where {T<:AbstractTransposeMethod}
    print(io, nameof(T))
end

_init_request_set(n) = MPI.RequestSet([MPI.Request() for _ = 1:n])

"""
    Transposition

Holds data for transposition between two pencil configurations.

---

    Transposition(dest::PencilArray{T,N}, src::PencilArray{T,N};
                  method = Transpositions.PointToPoint())

Prepare transposition of arrays from one pencil configuration to the other.

The two pencil configurations must be compatible for transposition:

- they must share the same MPI Cartesian topology,

- they must have the same global data size,

- the decomposed dimensions must be almost the same, with at most one
  difference.
  For instance, if the input of a 3D dataset is decomposed in `(2, 3)`, then the
  output may be decomposed in `(1, 3)` or in `(2, 1)`, but not in `(1, 2)`.
  **Note that the order of the decomposed dimensions (as passed to the `Pencil`
  constructor) matters.**
  If the decomposed dimensions are the same, then no transposition is performed,
  and data is just copied if needed.

The `src` and `dest` arrays may be aliased (they can share memory space).

# Performance tuning

The `method` argument allows to choose between transposition implementations.
This can be useful to tune performance of MPI data transfers.
Two values are currently accepted:

- `Transpositions.PointToPoint()` uses non-blocking point-to-point data transfers
  (`MPI_Isend` and `MPI_Irecv`).
  This may be more performant since data transfers are interleaved with local
  data transpositions (index permutation of received data).
  This is the default.

- `Transpositions.Alltoallv()` uses collective `MPI_Alltoallv` for global data
  transpositions.
"""
struct Transposition{T, N,
                     PencilIn  <: Pencil,
                     PencilOut <: Pencil,
                     ArrayIn   <: PencilArray{T,N},
                     ArrayOut  <: PencilArray{T,N},
                     M  <: AbstractTransposeMethod,
                    }
    Pi :: PencilIn
    Po :: PencilOut
    Ai :: ArrayIn
    Ao :: ArrayOut
    method :: M
    dim :: Union{Nothing,Int}  # dimension along which transposition is performed
    send_requests :: MPI.RequestSet
    send_buf:: AbstractVector{T} 
    recv_buf:: AbstractVector{T}
    length_send :: Int
    length_recv_total:: Int
    #length_self:: Int

    function Transposition(Ao::PencilArray{T,N}, Ai::PencilArray{T,N};
                           method = PointToPoint()) where {T,N}
        Pi = pencil(Ai)
        Po = pencil(Ao)

        # Verifications
        if extra_dims(Ai) !== extra_dims(Ao)
            throw(ArgumentError(
                "incompatible number of extra dimensions of PencilArrays: " *
                "$(extra_dims(Ai)) != $(extra_dims(Ao))"))
        end

        assert_compatible(Pi, Po)

        # The `decomp_dims` tuples of both pencils must differ by at most one
        # value (as just checked by `assert_compatible`). The transposition
        # is performed along the dimension R where that difference happens.
        dim = findfirst(decomposition(Pi) .!= decomposition(Po))

        reqs = MPI.RequestSet()

        length_self = let
            range_intersect = map(intersect, Pi.axes_local, Po.axes_local)
            prod(map(length, range_intersect)) * prod(extra_dims(Ai))
        end
    
    
        length_send = length(Ai) - length_self
        length_recv_total = length(Ao)
        backend = get_backend(Ai)

        send_buf = KernelAbstractions.zeros(backend, T, length_send)
        recv_buf = KernelAbstractions.zeros(backend, T, length_recv_total)
      # @show sizeof(send_buf), sizeof(recv_buf)
      @assert length(send_buf) >= length_send && length(recv_buf) >= length_recv_total

        new{T, N, typeof(Pi), typeof(Po), typeof(Ai), typeof(Ao), typeof(method)}(Pi, Po, Ai, Ao, method, dim, reqs, send_buf, recv_buf, length_send, length_recv_total)

    end
end
"""
    MPI.Waitall(t::Transposition)

Wait for completion of all unfinished MPI communications related to the
transposition.
"""
function MPI.Waitall(t::Transposition)
    isempty(t.send_requests) || MPI.Waitall(t.send_requests)
    nothing
end

function MPI.Waitall!(t::Transposition)
    @warn """
    MPI.Waitall!(t::Transposition) is deprecated and will be soon removed.
    Use MPI.Waitall(t) instead (without the `!`).
    """
    MPI.Waitall(t)
end

"""
    transpose!(t::Transposition; waitall=true)
    transpose!(dest::PencilArray{T,N}, src::PencilArray{T,N};
               method = Transpositions.PointToPoint())

Transpose data from one pencil configuration to the other.

The first variant allows to optionally delay the wait for MPI send operations to
complete.
This is useful if the caller wants to perform other operations with the already received data.
To do this, the caller should pass `waitall = false`, and manually invoke
[`MPI.Waitall`](@ref) on the `Transposition` object once the operations are
done.
Note that this option only has an effect when the transposition method is
`PointToPoint`.

See [`Transposition`](@ref) for details.
"""
function transpose! end

function transpose!(
        dest::PencilArray, src::PencilArray;
        method::AbstractTransposeMethod = PointToPoint(),
    )
    dest === src && return dest  # same pencil & same data
    t = Transposition(dest, src, method=method)
    transpose!(t, waitall=true)
    dest
end

function transpose!(t::Transposition; waitall=true)
    timer = Pencils.timer(t.Pi)
    @timeit_debug timer "transpose!" begin
        transpose_impl!(t.dim, t)
        if waitall
            @timeit_debug timer "wait send" MPI.Waitall(t)
        end
    end
    t
end

function assert_compatible(p::Pencil, q::Pencil)
    if p.topology !== q.topology
        throw(ArgumentError("pencil topologies must be the same."))
    end
    if p.size_global !== q.size_global
        throw(ArgumentError(
            "global data sizes must be the same between different pencil " *
            " configurations. Got $(p.size_global) ≠ $(q.size_global)."))
    end
    # Check that decomp_dims differ on at most one value.
    dp, dq = map(decomposition, (p, q))
    if sum(dp .!= dq) > 1
        throw(ArgumentError(
            "pencil decompositions must differ in at most one dimension. " *
            "Got decomposed dimensions $dp and $dq."))
    end
    nothing
end

# Reinterpret UInt8 vector as a different type of array.
# The input array should have enough space for the reinterpreted array with the
# given dimensions.
# This is a workaround to the performance issues when using `reinterpret`.
# See for instance:
# - https://discourse.julialang.org/t/big-overhead-with-the-new-lazy-reshape-reinterpret/7635
# - https://github.com/JuliaLang/julia/issues/28980
function unsafe_as_array(::Type{T}, x::AbstractVector{UInt8}, dims) where {T}
    p = typeof_ptr(x){T}(pointer(x))
    unsafe_wrap(typeof_array(x), p, dims, own=false)
end

# Only local transposition.
function transpose_impl!(::Nothing, t::Transposition)
    Pi = t.Pi
    Po = t.Po
    Ai = t.Ai
    Ao = t.Ao
    timer = Pencils.timer(Pi)

    # Both pencil configurations are identical, so we just copy the data,
    # permuting dimensions if needed.
    @assert size_local(Ai) === size_local(Ao)
    ui = parent(Ai)
    uo = parent(Ao)

    if permutation(Pi) == permutation(Po)
        @timeit_debug timer "copy!" copy!(uo, ui)
    else
        @timeit_debug timer "permute_local!" permute_local!(Ao, Ai)
    end

    t
end

function permute_local!(Ao::PencilArray{T,N},
                        Ai::PencilArray{T,N}) where {T, N}
    Pi = pencil(Ai)
    Po = pencil(Ao)

    perm = let
        perm_base = permutation(Po) / permutation(Pi)  # relative permutation
        p = append(perm_base, Val(ndims_extra(Ai)))
        Tuple(p)
    end

    ui = parent(Ai)
    uo = parent(Ao)

    inplace = Base.mightalias(ui, uo)

    if inplace
        # TODO optimise in-place version?
        # For now we permute into a temporary buffer, and then we copy to `Ao`.
        # We reuse `recv_buf` used for MPI transposes.
        buf = let x = Pi.recv_buf
            n = length(uo)
            dims = size(uo)
            resize!(x, sizeof(T) * n)
            vec = unsafe_as_array(T, x, n)
            reshape(vec, dims)
        end
        @strided permutedims!(buf, ui, perm)
        copy!(uo, buf)
    else
        # Permute directly onto the output.
        @strided permutedims!(uo, ui, perm)
    end

    Ao
end

function mpi_buffer(buf::AbstractArray{T}, off, length) where {T}
    inds = (off + 1):(off + length)
    v = view(buf, inds)
    MPI.Buffer(v)
end

# Transposition among MPI processes in a subcommunicator.
# R: index of MPI subgroup (dimension of MPI Cartesian topology) along which the
# transposition is performed.
function transpose_impl!(R::Int, t::Transposition{T}) where {T}
    @assert t.dim === R
    Pi = t.Pi
    Po = t.Po
    Ai = t.Ai
    Ao = t.Ao
    method = t.method
    timer = Pencils.timer(Pi)

    @assert Pi.topology === Po.topology
    @assert extra_dims(Ai) === extra_dims(Ao)

    topology = Pi.topology
    comm = topology.subcomms[R]  # exchange among the subgroup R
    Nproc = topology.dims[R]
    subcomm_ranks = topology.subcomm_ranks[R]
    myrank = subcomm_ranks[topology.coords_local[R]]  # rank in subgroup

    remote_inds = get_remote_indices(R, topology.coords_local, Nproc)


    length_self = let
        range_intersect = map(intersect, Pi.axes_local, Po.axes_local)
        prod(map(length, range_intersect)) * prod(extra_dims(Ai))
    end
    length_send = length(Ai) - length_self
    length_recv_total = length(Ao)
    # @show sizeof(send_buf), sizeof(recv_buf)
    send_buf = t.send_buf
    recv_buf = t.recv_buf
    recv_offsets = Vector{Int}(undef, Nproc) 
    @assert length(send_buf) >= length_send && length(recv_buf) >= length_recv_total

    req_length = method === Alltoallv() ? 0 : Nproc
    send_req = t.send_requests :: MPI.RequestSet
    while length(send_req) < req_length
        push!(send_req, MPI.Request())
    end
    recv_req = _init_request_set(req_length) :: MPI.RequestSet
    @assert length(send_req) == length(recv_req) == req_length

    buffers = (send_buf, recv_buf)
  #  @show sizeof(send_buf), sizeof(recv_buf)
    # We use RequestSet to avoid some allocations
    requests = (send_req, recv_req)

    # 1. Pack and send data.
    @timeit_debug timer "pack data" index_local_req = transpose_send!(
        buffers, recv_offsets, requests, length_self, remote_inds,
        (comm, subcomm_ranks, myrank),
        Ao, Ai, method, timer,
    )

    # 2. Unpack data and perform local transposition.
    @timeit_debug timer "unpack data" transpose_recv!(
        recv_buf, recv_offsets, recv_req,
        remote_inds, index_local_req,
        Ao, Ai, method, timer,
    )

    t
end

function transpose_send!(
        (send_buf, recv_buf),
        recv_offsets, requests,
        length_self, remote_inds,
        (comm, subcomm_ranks, myrank),
        Ao::PencilArray{T}, Ai::PencilArray{T},
        method::AbstractTransposeMethod,
        timer::TimerOutput,
    ) where {T}
    Pi = pencil(Ai)  # input (sent data)
    Po = pencil(Ao)  # output (received data)

    idims_local = Pi.axes_local
    odims_local = Po.axes_local

    idims = Pi.axes_all
    odims = Po.axes_all

    exdims = extra_dims(Ai)
    prod_extra_dims = prod(exdims)

    isend = 0  # current index in send_buf
    irecv = 0  # current index in recv_buf

    index_local_req = -1  # request index associated to local exchange

    # Data received from other processes.
    length_recv = length(Ao) - length_self

    Nproc = length(subcomm_ranks)
    @assert Nproc == MPI.Comm_size(comm)
    @assert myrank == MPI.Comm_rank(comm)

    buf_info = make_buffer_info(method, (send_buf, recv_buf), Nproc)

    for (n, ind) in enumerate(remote_inds)
        # Global data range that I need to send to process n.
        srange = map(intersect, idims_local, odims[ind])
        length_send_n = prod(map(length, srange)) * prod_extra_dims
        local_send_range = to_local(Pi, srange, MemoryOrder())

        # Determine amount of data to be received.
        rrange = map(intersect, odims_local, idims[ind])
        length_recv_n = prod(map(length, rrange)) * prod_extra_dims
        recv_offsets[n] = irecv

        rank = subcomm_ranks[n]  # actual rank of the other process

        if rank == myrank
            # Copy directly from `Ai` to `recv_buf`.
            # For convenience, data is put at the end of `recv_buf`.
            # This makes it easier to implement an alternative based on MPI_Alltoallv.
            @assert length_recv_n == length_self
            recv_offsets[n] = length_recv
            @timeit_debug timer "copy_range!" copy_range!(
                recv_buf, length_recv, Ai, local_send_range,
            )
            transpose_send_self!(method, n, requests, buf_info)
            index_local_req = n
        else
            # Copy data into contiguous buffer, then send the buffer.
            @timeit_debug timer "copy_range!" copy_range!(
                send_buf, isend, Ai, local_send_range,
            )
            transpose_send_other!(
                method, buf_info, (length_send_n, length_recv_n), n,
                requests, (rank, comm), eltype(Ai),
            )
            irecv += length_recv_n
            isend += length_send_n
        end
    end

    if method === Alltoallv()
        # This @view is needed because the Alltoallv wrapper checks that the
        # length of the buffer is consistent with recv_counts.
        recv_buf_view = @view recv_buf[1:length_recv]
        @timeit_debug timer "MPI.Alltoallv!" MPI.Alltoallv!(
            MPI.VBuffer(send_buf, buf_info.send_counts),
            MPI.VBuffer(recv_buf_view, buf_info.recv_counts),
            comm,
        )
    end

    index_local_req
end

function make_buffer_info(::PointToPoint, (send_buf, recv_buf), Nproc)
    (
        send_buf = send_buf,
        recv_buf = recv_buf,
        send_offset = Ref(0),
        recv_offset = Ref(0),
    )
end

function make_buffer_info(::Alltoallv, bufs, Nproc)
    counts = Vector{Cint}(undef, Nproc)
    (
        send_counts = counts,
        recv_counts = similar(counts),
    )
end

function transpose_send_self!(::PointToPoint, n, (send_req, recv_req), etc...)
    send_req[n] = recv_req[n] = MPI.REQUEST_NULL
    nothing
end

function transpose_send_self!(::Alltoallv, n, reqs, buf_info)
    # Don't send data to myself via Alltoallv.
    buf_info.send_counts[n] = buf_info.recv_counts[n] = zero(Cint)
    nothing
end

function transpose_send_other!(
        ::PointToPoint, info, (length_send_n, length_recv_n),
        n, (send_req, recv_req), (rank, comm), ::Type{T}
    ) where {T}
    # Exchange data with the other process (non-blocking operations).
    # Note: data is sent and received with the permutation associated to Pi.
    tag = 42
    send_req[n] = MPI.Isend(
        mpi_buffer(info.send_buf, info.send_offset[], length_send_n),
        rank, tag, comm
    )
    recv_req[n] = MPI.Irecv!(
        mpi_buffer(info.recv_buf, info.recv_offset[], length_recv_n),
        rank, tag, comm
    )
    info.send_offset[] += length_send_n
    info.recv_offset[] += length_recv_n
    nothing
end

function transpose_send_other!(
        ::Alltoallv, buf_info, (length_send_n, length_recv_n), n, args...
    )
    buf_info.send_counts[n] = length_send_n
    buf_info.recv_counts[n] = length_recv_n
    nothing
end

function transpose_recv!(
        recv_buf, recv_offsets, recv_req,
        remote_inds, index_local_req,
        Ao::PencilArray, Ai::PencilArray,
        method::AbstractTransposeMethod,
        timer::TimerOutput,
    )
    Pi = pencil(Ai)  # input (sent data)
    Po = pencil(Ao)  # output (received data)

    odims_local = Po.axes_local
    idims = Pi.axes_all

    exdims = extra_dims(Ao)
    prod_extra_dims = prod(exdims)

    # Relative index permutation to go from Pi ordering to Po ordering.
    perm = permutation(Po) / permutation(Pi)

    Nproc = length(remote_inds)

    for m = 1:Nproc
        if method === Alltoallv()
            n = m
        elseif m == 1
            n = index_local_req  # copy local data first
        else
            @timeit_debug timer "wait receive" n = MPI.Waitany(recv_req)
        end

        # Non-permuted global indices of received data.
        ind = remote_inds[n]
        g_range = map(intersect, odims_local, idims[ind])

        # length_recv_n = prod(map(length, g_range)) * prod_extra_dims
        off = recv_offsets[n]

        # Local output data range in the **input** permutation.
        o_range_iperm = permutation(Pi) * to_local(Po, g_range, LogicalOrder())

        # Copy data to `Ao`, permuting dimensions if required.
        @timeit_debug timer "copy_permuted!" copy_permuted!(
            Ao, o_range_iperm, recv_buf, off, perm,
        )
    end

    Ao
end

# Cartesian indices of the remote MPI processes included in the subgroup of
# index `R`.
# Example: if coords_local = (2, 3, 5) and R = 1, then this function returns the
# indices corresponding to (:, 3, 5).
function get_remote_indices(R::Int, coords_local::Dims{M}, Nproc::Int) where M
    t = ntuple(Val(M)) do i
        if i == R
            1:Nproc
        else
            c = coords_local[i]
            c:c
        end
    end
    CartesianIndices(t)
end

# Specialisation for CPU arrays.
function copy_range!(
        dest::Vector, dest_offset::Integer,
        src::PencilArray, src_range_memorder::NTuple,
    )
    exdims = extra_dims(src)
    n = dest_offset
    src_p = parent(src)  # array with non-permuted indices (memory order)
    for K in CartesianIndices(exdims)
        for I in CartesianIndices(src_range_memorder)
            @inbounds dest[n += 1] = src_p[I, K]
        end
    end
    dest
end

@kernel function pack_kernel!(dest, src, nfast, nmid, nslow, offset)
    idx = @index(Global)  
    line_stride = nfast
    plane_stride = nfast * nmid
    if idx <= nmid * nslow
        j = ((idx - 1) ÷ nfast) % nmid + 1
        k = (idx - 1) ÷ (nfast * nmid) + 1
        i = (idx - 1) % nfast + 1

        src_idx = (j - 1) * line_stride + (k - 1) * plane_stride + i
        dest_idx = offset + idx
        @inbounds dest[dest_idx] = src[src_idx]
   end
end

function copy_range!(
        dest::AbstractVector, dest_offset::Integer,
        src::PencilArray, src_dims::NTuple
    )
    src_p = parent(src)
    nfast, nmid, nslow = size(src_p)

    total_elements = nfast * nmid * nslow
    offset = dest_offset
    backend = KernelAbstractions.get_backend(dest)
    work_size = total_elements  

    pack_kernel!(backend)(dest, src_p, nfast, nmid, nslow, offset, ndrange=(total_elements,))
#    KernelAbstractions.synchronize(backend)
   
    return dest
end
"""
function copy_range!(
        dest::AbstractVector, dest_offset::Integer,
        src::PencilArray, src_range_memorder::NTuple,
    )
    exdims = extra_dims(src)
    n = dest_offset
    src_p = parent(src)  # array with non-permuted indices (memory order)
    Ks = CartesianIndices(exdims)
    Is = CartesianIndices(src_range_memorder)
    len = length(Is) * length(Ks)
    src_view = @view src_p[Is, Ks]
    dst_view = @view dest[(n + 1):(n + len)]
    # TODO this allocates on GPUArrays... can it be improved?
    copyto!(dst_view, src_view)
    dest
end
"""
function copy_permuted!(
        dst::PencilArray, o_range_iperm::NTuple,
        src::AbstractVector, src_offset::Integer,
        perm::AbstractPermutation,
    )
    N = ndims(dst)
    P = length(o_range_iperm)
    exdims = extra_dims(dst)
    E = length(exdims)
    @assert P + E == N

    src_dims = (map(length, o_range_iperm)..., exdims...)
    src_view = _viewreshape(src, src_dims, src_offset)

    dst_inds = perm * o_range_iperm  
    _permutedims!(dst, src_view, dst_inds, perm)

    dst
end

# Case of CPU arrays.
# Note that Strided uses scalar indexing at some point, and for that reason it
# doesn't work with GPU arrays.
function _viewreshape(src::Vector, src_dims, n)
    N = prod(src_dims)
    v = Strided.sview(src, (n + 1):(n + N))
    Strided.sreshape(v, src_dims)
end

# Generic case, used in particular for GPU arrays.
function _viewreshape(src::AbstractVector, src_dims, n)
    @boundscheck begin
        N = prod(src_dims)
        checkbounds(src, (n + 1):(n + N))
    end
    # On GPUs, we use unsafe_wrap to make sure that the returned array is an
    # AbstractGPUArray, for which `permutedims!` is implemented in GPUArrays.jl.
    unsafe_wrap(typeof_array(src), pointer(src, n + 1), src_dims)
end

function _permutedims!(dst::PencilArray, src, dst_inds, perm)
    exdims = extra_dims(dst)
    v = view(parent(dst), dst_inds..., map(Base.OneTo, exdims)...)
    _permutedims!(typeof_array(pencil(dst)), dst, v, src, perm)
end

# Specialisation for CPU arrays.
# Note that v_in is the raw array (in memory order) wrapped by a PencilArray.
function _permutedims!(::Type{Array}, dest, v_in::SubArray, src, perm)
    v = StridedView(v_in)
    vperm = if isidentity(perm)
        v
    else
        E = ndims(v) - length(perm)  # number of "extra dims"
        pperm = append(perm, Val(E))
        # This is the equivalent of a PermutedDimsArray in Strided.jl.
        # Note that this is a lazy object (a StridedView)!
        permutedims(v, Tuple(inv(pperm))) :: StridedView
    end
    copyto!(vperm, src)
end

@kernel function unpack_kernel!(src, dest, ::Val{(1, 2, 3)}, nfast, nmid, nslow)
    idx = @index(Global)
    if idx > nfast * nmid * nslow
        nothing
    end
    i = (idx - 1) % nfast + 1
    j = ((idx - 1) ÷ nfast) % nmid + 1
    k = (idx - 1) ÷ (nfast * nmid) + 1
    @inbounds dest[i, j, k] = src[i, j, k]
end

@kernel function unpack_kernel!(src, dest, ::Val{(1, 3, 2)}, nfast, nmid, nslow)
    idx = @index(Global)
    if idx > nfast * nmid * nslow
        nothing
    end
    i = (idx - 1) % nfast + 1
    k = ((idx - 1) ÷ nfast) % nmid + 1
    j = (idx - 1) ÷ (nfast * nmid) + 1
    @inbounds dest[i, k, j] = src[i, j, k]
end

@kernel function unpack_kernel!(src, dest, ::Val{(2, 1, 3)}, nfast, nmid, nslow)
    idx = @index(Global)
    if idx > nfast * nmid * nslow
        nothing
    end
    j = (idx - 1) % nfast + 1
    i = ((idx - 1) ÷ nfast) % nmid + 1
    k = (idx - 1) ÷ (nfast * nmid) + 1
    @inbounds dest[j, i, k] = src[i, j, k]
end

@kernel function unpack_kernel!(src, dest, ::Val{(2, 3, 1)}, nfast, nmid, nslow)
    idx = @index(Global)
    if idx > nfast * nmid * nslow
        nothing
    end
    j = (idx - 1) % nfast + 1
    k = ((idx - 1) ÷ nfast) % nmid + 1
    i = (idx - 1) ÷ (nfast * nmid) + 1
    @inbounds dest[j, k, i] = src[i, j, k]
end

@kernel function unpack_kernel!(src, dest, ::Val{(3, 1, 2)}, nfast, nmid, nslow)
    idx = @index(Global)
    if idx > nfast * nmid * nslow
        nothing
    end
    k = (idx - 1) % nfast + 1
    i = ((idx - 1) ÷ nfast) % nmid + 1
    j = (idx - 1) ÷ (nfast * nmid) + 1
    @inbounds dest[k, i, j] = src[i, j, k]
end


# General case, used in particular for GPU arrays.
function _permutedims!(::Type{<:AbstractGPUArray}, dest::PencilArray, v::SubArray, src, perm)
    if isidentity(perm)
        copyto!(v, src)
    elseE = ndims(v) - length(perm)  # number of "extra dims"
    pperm = append(perm, Val(E))
    dest_p = parent(dest)
    nfast, nmid, nslow = size(dest_p)

    total_elements = nfast * nmid * nslow
    work_size = total_elements  
    backend = KernelAbstractions.get_backend(src)

    unpack_kernel!(backend)(src, v, Val(Tuple(pperm)), nfast, nmid, nslow, ndrange=size(src))
    KernelAbstractions.synchronize(backend)
    end
   v
end

end  # module Transpositions
