#include <iostream>
#include <limits>
#include <assert.h>
#include <fstream>
#include <string.h>
#include <cuda_runtime.h>
#include "debug_macros.hpp"

#include "frame.h"

namespace popart {

using namespace std;

/*************************************************************
 * Frame
 *************************************************************/

void Frame::hostDebugDownload( )
{
    delete [] _h_debug_plane;
    _h_debug_plane = new unsigned char[ getWidth() * getHeight() ];

    delete [] _h_debug_gauss_plane;
    _h_debug_gauss_plane = new float[ getWidth() * getHeight() ];

    cerr << "Trigger download of debug plane: "
         << "(" << _d_plane.cols << "," << _d_plane.rows << ") pitch " << _d_plane.step
         << " to "
         << "(" << getWidth() << "," << getHeight() << ")" << endl;
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_plane, getWidth(),
                              _d_plane.data, _d_plane.step,
                              _d_plane.cols,
                              _d_plane.rows,
                              cudaMemcpyDeviceToHost, _stream );
    cerr << "Trigger download of Gaussian debug plane: "
         << "(" << _d_gaussian.cols << "," << _d_gaussian.rows << ") pitch " << _d_gaussian.step
         << " to "
         << "(" << getWidth() << "," << getHeight() << ")" << endl;
    POP_CUDA_MEMCPY_2D_ASYNC( _h_debug_gauss_plane, getWidth() * sizeof(float),
                              _d_gaussian.data, _d_gaussian.step,
                              _d_gaussian.cols * sizeof(float),
                              _d_gaussian.rows,
                              cudaMemcpyDeviceToHost, _stream );
}

void Frame::writeDebugPlane( const char* filename, const cv::cuda::PtrStepSzb& plane )
{
    assert( plane.data );

    ofstream of( filename );
    of << "P5" << endl
       << plane.cols << " " << plane.rows << endl
       << "255" << endl;
    of.write( (char*)plane.data, plane.cols * plane.rows );
}

__host__
static void testme( cv::cuda::PtrStepSzf src )
{
    size_t non_null_ct = 0;
    float minval = 1000.0f;
    float maxval = -1000.0f;
    for( size_t i=0; i<src.rows; i++ )
        for( size_t j=0; j<src.cols; j++ ) {
            float f = src.ptr(i)[j];
            if( f != 0.0f )
                non_null_ct++;
            minval = min( minval, f );
            maxval = max( maxval, f );
        }
    printf("testme: There are %lu non-null values in the Gaussian end result (min %f, max %f)\n", (unsigned long)non_null_ct, minval, maxval );
}

void Frame::writeDebugPlane( const char* filename, const cv::cuda::PtrStepSzf& plane )
{
    cerr << "Enter " << __FUNCTION__ << endl;

    ofstream of( filename );
    of << "P5" << endl
       << plane.cols << " " << plane.rows << endl
       << "255" << endl;

    float minval = 1000.0f;  // std::numeric_limits<float>::max();
    float maxval = -1000.0f; // std::numeric_limits<float>::min();
    // for( uint32_t i=0; i<plane.rows*plane.cols; i++ ) {
    for( size_t i=0; i<plane.rows; i++ ) {
        for( size_t j=0; j<plane.cols; j++ ) {
            float f = plane.ptr(i)[j];
            // float f = plane.data[i];
            minval = min( minval, f );
            maxval = max( maxval, f );
        }
    }
    cerr << "    step size is " << plane.step << endl;
    cerr << "    found minimum value " << minval << endl;
    cerr << "    found maximum value " << maxval << endl;

    testme( plane );

    maxval = 255.0f / ( maxval - minval );
    for( uint32_t i=0; i<plane.rows*plane.cols; i++ ) {
        float f = plane.data[i];
        f = ( f - minval ) * maxval;
        unsigned char uc = (unsigned char)f;
        of << uc;
    }

    cerr << "Leave " << __FUNCTION__ << endl;
}

void Frame::hostDebugCompare( unsigned char* pix )
{
    bool found_mistake = false;
    size_t mistake_ct = 0;

    for( int h=0; h<_d_plane.rows; h++ ) {
        for( int w=0; w<_d_plane.cols; w++ ) {
            if( pix[h*_d_plane.cols+w] != _h_debug_plane[h*_d_plane.cols+w] ) {
                mistake_ct++;
                if( found_mistake == false ) {
                    found_mistake = true;
                    cerr << "Found first error at (" << w << "," << h << "): "
                         << "orig " << pix[h*_d_plane.cols+w]
                         << "copy " << _h_debug_plane[h*_d_plane.cols+w]
                         << endl;
                }
            }
        }
    }
    if( found_mistake ) {
        cerr << "Total errors: " << mistake_ct << endl;
    } else {
        cerr << "Found no difference between original and re-downloaded frame" << endl;
    }
}

void Frame::writeHostDebugPlane( string filename )
{
    string s = filename + ".pgm";
    cv::cuda::PtrStepSzb b( getHeight(),
                            getWidth(),
                            _h_debug_plane,
                            getWidth() );
    writeDebugPlane( s.c_str(), b );

    s = filename + "-gauss.pgm";
    cv::cuda::PtrStepSzf f( getHeight(),
                            getWidth(),
                            _h_debug_gauss_plane,
                            getWidth()*sizeof(float) );
    writeDebugPlane( s.c_str(), f );
}

}; // namespace popart

