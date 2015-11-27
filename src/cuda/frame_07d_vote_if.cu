#include <iostream>
#include <algorithm>
#include <limits>
#include <cuda_runtime.h>
#include <cub/cub.cuh>
#include <stdio.h>
#include "debug_macros.hpp"
#include "debug_is_on_edge.h"

#include "frame.h"
#include "assist.h"
#include "onoff.h"

using namespace std;

namespace popart {

struct NumVotersIsGreaterEqual
{
    DevEdgeList<TriplePoint> _array;
    int                      _compare;

    __host__ __device__
    __forceinline__
    NumVotersIsGreaterEqual( int compare, DevEdgeList<TriplePoint> _d_array )
        : _compare(compare)
        , _array( _d_array )
    {}

    __device__
    __forceinline__
    bool operator()(const int &a) const {
        return (_array.ptr[a]._winnerSize >= _compare);
    }
};

#ifdef USE_SEPARABLE_COMPILATION
namespace vote {

__global__
void dp_call_05_if(
    DevEdgeList<TriplePoint> chainedEdgeCoords, // input
    DevEdgeList<int>         seedIndices,       // output
    DevEdgeList<int>         seedIndices2,      // input
    cv::cuda::PtrStepSzb     intermediate,      // buffer
    const int                param_minVotesToSelectCandidate ) // input param
{
    if( seedIndices.getSize() == 0 ) {
        seedIndices2.setSize(0);
        return;
    }

    cudaStream_t childStream;
    cudaStreamCreateWithFlags( &childStream, cudaStreamNonBlocking );

    void*  assist_buffer = (void*)intermediate.data;
    size_t assist_buffer_sz = intermediate.step * intermediate.rows;

    /* Filter all chosen inner points that have fewer
     * voters than required by Parameters.
     */
    NumVotersIsGreaterEqual select_op( param_minVotesToSelectCandidate,
                                       chainedEdgeCoords );
    cub::DeviceSelect::If( assist_buffer,
                           assist_buffer_sz,
                           seedIndices2.ptr,
                           seedIndices.ptr,
                           seedIndices.getSizePtr(),
                           seedIndices2.getSize(),
                           select_op,
                           childStream,     // use stream 0
                           DEBUG_CUB_FUNCTIONS ); // synchronous for debugging

    cudaStreamDestroy( childStream );
}

} // namespace vote

__host__
bool Frame::applyVoteIf( const cctag::Parameters& params )
{
    vote::dp_call_05_if
        <<<1,1,0,_stream>>>
        ( _vote._chained_edgecoords.dev,  // input
          _vote._seed_indices.dev,        // output
          _vote._seed_indices_2.dev,      // input
          cv::cuda::PtrStepSzb(_d_intermediate), // buffer
          params._minVotesToSelectCandidate ); // input param
    POP_CHK_CALL_IFSYNC;

    _vote._seed_indices.copySizeFromDevice( _stream, EdgeListCont );

    return true;
}
#else // not USE_SEPARABLE_COMPILATION
__host__
bool Frame::applyVoteIf( const cctag::Parameters& params )
{
    cudaError_t err;

    void*  assist_buffer = (void*)_d_intermediate.data;
    size_t assist_buffer_sz;

    NumVotersIsGreaterEqual select_op( params._minVotesToSelectCandidate,
                                       _vote._chained_edgecoords.dev );
#ifdef CUB_INIT_CALLS
    assist_buffer_sz  = 0;
    err = cub::DeviceSelect::If( 0,
                                 assist_buffer_sz,
                                 _vote._seed_indices_2.dev.ptr,
                                 _vote._seed_indices.dev.ptr,
                                 _vote._seed_indices.dev.getSizePtr(),
                                 _vote._seed_indices_2.host.size,
                                 select_op,
                                 _stream,
                                 DEBUG_CUB_FUNCTIONS );

    POP_CUDA_FATAL_TEST( err, "CUB DeviceSelect::If failed in init test" );

    if( assist_buffer_sz >= _d_intermediate.step * _d_intermediate.rows ) {
        std::cerr << "cub::DeviceSelect::If requires too much intermediate memory. Crashing." << std::endl;
        exit( -1 );
    }
#else
    // THIS CODE WORKED BEFORE
    assist_buffer_sz = _d_intermediate.step * _d_intermediate.rows;
#endif

    /* Filter all chosen inner points that have fewer
     * voters than required by Parameters.
     */
    err = cub::DeviceSelect::If( assist_buffer,
                                 assist_buffer_sz,
                                 _vote._seed_indices_2.dev.ptr,
                                 _vote._seed_indices.dev.ptr,
                                 _vote._seed_indices.dev.getSizePtr(),
                                 _vote._seed_indices_2.host.size,
                                 select_op,
                                 _stream,
                                 DEBUG_CUB_FUNCTIONS );
    POP_CHK_CALL_IFSYNC;
    POP_CUDA_FATAL_TEST( err, "CUB DeviceSelect::If failed" );

    _vote._seed_indices.copySizeFromDevice( _stream, EdgeListCont );
    return true;
}
#endif // not USE_SEPARABLE_COMPILATION

} // namespace popart
