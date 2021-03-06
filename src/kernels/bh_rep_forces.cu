// TODO: add copyright

/*
        Traverses the tree and calculates approximate repulsive forces via Barnes-Hut.

        t-SNE repulsive forces are given by qij*qijN(y_i - y_j). This also simultaneously
        calculates tne normalization constant N.

*/

#include "include/kernels/bh_rep_forces.h"

/******************************************************************************/
/*** compute force ************************************************************/
/******************************************************************************/

__global__
void tsnecuda::bh::ForceCalculationKernel(volatile int * __restrict__ errd,
                                          volatile float * __restrict__ x_vel_device,
                                          volatile float * __restrict__ y_vel_device,
                                          volatile float * __restrict__ normalization_vec_device,
                                          const int * __restrict__ cell_sorted,
                                          const int * __restrict__ children,
                                          const float * __restrict__ cell_mass,
                                          volatile float * __restrict__ x_pos_device,
                                          volatile float * __restrict__ y_pos_device,
                                          const float theta,
                                          const float epsilon,
                                          const int num_nodes,
                                          const int num_points,
                                          const int maxdepth_bh_tree,
                                          const int repulsive_force_threads
                                          )
{
    register int i, j, k, n, depth, base, sbase, diff, pd, nd;
    register float px, py, vx, vy, dx, dy, normsum, tmp, mult;
    extern __shared__ int force_shared_memory[];
    int* pos = (int*) force_shared_memory;
    int* node = (int*) (pos + maxdepth_bh_tree*repulsive_force_threads/32);
    float* dq = (float*) (node + maxdepth_bh_tree*repulsive_force_threads/32);

    if (0 == threadIdx.x) {
        dq[0] = (radiusd * radiusd) / (theta * theta); 
        for (i = 1; i < maxdepthd; i++) {
                dq[i] = dq[i - 1] * 0.25f; // radius is halved every level of tree so squared radius is quartered
                dq[i - 1] += epsilon;
        }
        dq[i - 1] += epsilon;

        if (maxdepthd > maxdepth_bh_tree) {
            *errd = maxdepthd;
        }
    }
    __syncthreads();

    if (maxdepthd <= maxdepth_bh_tree) {
        // figure out first thread in each warp (lane 0)
        base = threadIdx.x / 32;
        sbase = base * 32;
        j = base * maxdepth_bh_tree;

        diff = threadIdx.x - sbase;
        // make multiple copies to avoid index calculations later
        if (diff < maxdepth_bh_tree) {
            dq[diff+j] = dq[diff];
        }
        __syncthreads();
        __threadfence_block();

        // iterate over all bodies assigned to thread
        for (k = threadIdx.x + blockIdx.x * blockDim.x; k < num_points; k += blockDim.x * gridDim.x) {
            i = cell_sorted[k];    // get permuted/sorted index
            // cache position info
            px = x_pos_device[i];
            py = y_pos_device[i];

            vx = 0.0f;
            vy = 0.0f;
            normsum = 0.0f;

            // initialize iteration stack, i.e., push root node onto stack
            depth = j;
            if (sbase == threadIdx.x) {
                pos[j] = 0;
                node[j] = num_nodes * 4;
            }

            do {
                // stack is not empty
                pd = pos[depth];
                nd = node[depth];
                while (pd < 4) {
                    // node on top of stack has more children to process
                    n = children[nd + pd];    // load child pointer
                    pd++;

                    if (n >= 0) {
                        dx = px - x_pos_device[n];
                        dy = py - y_pos_device[n];
                        tmp = dx*dx + dy*dy + epsilon; // distance squared plus small constant to prevent zeros
                        #if (CUDART_VERSION >= 9000)
                            if ((n < num_points) || __all_sync(__activemask(), tmp >= dq[depth])) {    // check if all threads agree that cell is far enough away (or is a body)
                        #else
                            if ((n < num_points) || __all(tmp >= dq[depth])) {
                        #endif
                                // from bhtsne - sptree.cpp
                            tmp = 1 / (1 + tmp);
                            mult = cell_mass[n] * tmp;
                            normsum += mult;
                            mult *= tmp;
                            vx += dx * mult;
                            vy += dy * mult;
                        } else {
                            // push cell onto stack
                            if (sbase == threadIdx.x) {    // maybe don't push and inc if last child
                                pos[depth] = pd;
                                node[depth] = nd;
                            }
                            depth++;
                            pd = 0;
                            nd = n * 4;
                        }
                    } else {
                        pd = 4;    // early out because all remaining children are also zero
                    }
                }
                depth--;    // done with this level
            } while (depth >= j);

            if (stepd >= 0) {
                // update velocity
                x_vel_device[i] += vx;
                y_vel_device[i] += vy;
                normalization_vec_device[i] = normsum - 1.0f; // subtract one for self computation (qii)
            }
        }
    }
}

void tsnecuda::bh::ComputeRepulsiveForces(tsnecuda::GpuOptions &gpu_opt,
                                          thrust::device_vector<int> &errd,
                                          thrust::device_vector<float> &repulsive_forces,
                                          thrust::device_vector<float> &normalization_vec,
                                          thrust::device_vector<int> &cell_sorted,
                                          thrust::device_vector<int> &children,
                                          thrust::device_vector<float> &cell_mass,
                                          thrust::device_vector<float> &points,
                                          const float theta,
                                          const float epsilon,
                                          const int num_nodes,
                                          const int num_points,
                                          const int num_blocks)
{
    tsnecuda::bh::ForceCalculationKernel<<<num_blocks * gpu_opt.repulsive_kernel_factor,
                                           gpu_opt.repulsive_kernel_threads,
                                           sizeof(int)*2*32*gpu_opt.repulsive_kernel_threads/32 +
                                           sizeof(float)*32*gpu_opt.repulsive_kernel_threads/32>>>(
                        thrust::raw_pointer_cast(errd.data()),
                        thrust::raw_pointer_cast(repulsive_forces.data()),
                        thrust::raw_pointer_cast(repulsive_forces.data() + num_nodes + 1),
                        thrust::raw_pointer_cast(normalization_vec.data()),
                        thrust::raw_pointer_cast(cell_sorted.data()),
                        thrust::raw_pointer_cast(children.data()),
                        thrust::raw_pointer_cast(cell_mass.data()),
                        thrust::raw_pointer_cast(points.data()),
                        thrust::raw_pointer_cast(points.data() + num_nodes + 1),
                        theta, epsilon, num_nodes, num_points, 32, //TODO: Encode this variable somewhere
                        gpu_opt.repulsive_kernel_threads
                    );
    GpuErrorCheck(cudaDeviceSynchronize());
}
