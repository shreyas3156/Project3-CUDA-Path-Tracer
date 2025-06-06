#include "pathtrace.h"

#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/sort.h>
#include <thrust/partition.h>
#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "intersections.h"
#include "interactions.h"
#include "OpenImageDenoise/oidn.hpp"

#define ERRORCHECK 1
#define STREAMCOMPACT 1
#define MATERIALSORT 0
#define DEPTH_OF_FIELD 1
#define BVC 1
#define DENOISING 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)

void checkCUDAErrorFn(const char* msg, const char* file, int line)
{
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err)
    {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file)
    {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#ifdef _WIN32
    getchar();
#endif // _WIN32
    exit(EXIT_FAILURE);
#endif // ERRORCHECK
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth)
{
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution, int iter, glm::vec3* image)
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y)
    {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
static Vertex* dev_vertices = NULL;
// TODO: static variables for device memory, any extra info you need, etc
static bool* dev_maskBuffer = NULL;
static int* dev_matKeys = NULL;
static glm::vec3* dev_denoised_image = NULL;
static glm::vec3* dev_normalImage = NULL;


void InitDataContainer(GuiDataContainer* imGuiData)
{
    guiData = imGuiData;
}

void pathtraceInit(Scene* scene)
{
    hst_scene = scene;

    const Camera& cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

    cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

    cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
    cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

    cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
    cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

    cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
    cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    cudaMalloc(&dev_vertices, scene->vertices.size() * sizeof(Vertex));
    cudaMemcpy(dev_vertices, scene->vertices.data(), scene->vertices.size() * sizeof(Vertex), cudaMemcpyHostToDevice);
    // TODO: initialize any extra device memeory you need
#if STREAMCOMPACT
    cudaMalloc(&dev_maskBuffer, pixelcount * sizeof(bool));
#endif

#if MATERIALSORT
    cudaMalloc(&dev_matKeys, pixelcount * sizeof(int));
#endif

#if DENOISING
    cudaMalloc(&dev_denoised_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_denoised_image, 0, pixelcount * sizeof(glm::vec3));
    cudaMalloc(&dev_normalImage, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_normalImage, 0, pixelcount * sizeof(glm::vec3));
#endif
    checkCUDAError("pathtraceInit");
}

void pathtraceFree()
{
    cudaFree(dev_image);  // no-op if dev_image is null
    cudaFree(dev_paths);
    cudaFree(dev_geoms);
    cudaFree(dev_materials);
    cudaFree(dev_intersections);
    cudaFree(dev_vertices);
    // TODO: clean up any extra device memory you created
#if STREAMCOMPACT
    cudaFree(dev_maskBuffer);
#endif

#if MATERIALSORT
    cudaFree(dev_matKeys);
#endif
#if DENOISING
    cudaFree(dev_denoised_image);
    cudaFree(dev_normalImage);
#endif
    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < cam.resolution.x && y < cam.resolution.y) {
        int index = x + (y * cam.resolution.x);
        PathSegment& segment = pathSegments[index];

        segment.ray.origin = cam.position;
        segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

#if 0
        // TODO: implement antialiasing by jittering the ray
        segment.ray.direction = glm::normalize(cam.view
            - cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
            - cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
        );
#else
        thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
        thrust::uniform_real_distribution<float> u01(0, 1);
        thrust::uniform_real_distribution<float> u02(0, 1);

        // toggle Anti-Aliasing
        float xJitter = u01(rng) - 0.5f;
        float yJitter = u01(rng) - 0.5f;

        segment.ray.direction = glm::normalize(cam.view
            - cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f +
                xJitter)
            - cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f +
                yJitter)
        );
#endif

#if     DEPTH_OF_FIELD
        glm::vec3 focalPoint = segment.ray.origin + segment.ray.direction * cam.focalDist;
        // initialize a separate RNG for depth-of-field
        thrust::default_random_engine rngDof = makeSeededRandomEngine(iter, index, 2);
        thrust::uniform_real_distribution<float> uniformDoF(0, 1);
        float sampleRadius = cam.aperture * glm::sqrt(float(uniformDoF(rngDof)));
        float sampleAngle = 2.0f * PI * uniformDoF(rngDof);
        glm::vec3 lensUV = sampleRadius * glm::vec3(cos(sampleAngle), sin(sampleAngle), 0.0f);

        segment.ray.origin += lensUV.x * cam.right + lensUV.y * cam.up;
        segment.ray.direction = glm::normalize(focalPoint - segment.ray.origin);
#endif

        segment.pixelIndex = index;
        segment.remainingBounces = traceDepth;
    }
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
    int depth,
    int num_paths,
    PathSegment* pathSegments,
    Geom* geoms,
    int geoms_size,
    ShadeableIntersection* intersections,
    Vertex* vertices,
    glm::vec3* dev_normalImage
)
{
    int path_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (path_index < num_paths)
    {
        PathSegment pathSegment = pathSegments[path_index];

        float t;
        glm::vec3 intersect_point;
        glm::vec3 normal;
        float t_min = FLT_MAX;
        int hit_geom_index = -1;
        bool outside = true;

        glm::vec3 tmp_intersect;
        glm::vec3 tmp_normal;

        // naive parse through global geoms

        for (int i = 0; i < geoms_size; i++)
        {
            Geom& geom = geoms[i];

            if (geom.type == CUBE)
            {
                t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
            }
            else if (geom.type == SPHERE)
            {
                t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
            }
            // TODO: add more intersection tests here... triangle? metaball? CSG?
            else if (geom.type == CUSTOM)
            {
                bool toggleCulling = false;
#if BVC
                toggleCulling = true;
#endif
                t = meshRayIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside,
                    vertices, toggleCulling);
            }
            // Compute the minimum t from the intersection tests to determine what
            // scene geometry object was hit first.
            if (t > 0.0f && t_min > t)
            {
                t_min = t;
                hit_geom_index = i;
                intersect_point = tmp_intersect;
                normal = tmp_normal;
            }
        }

        if (hit_geom_index == -1)
        {
            intersections[path_index].t = -1.0f;
        }
        else
        {
            // The ray hits something
            intersections[path_index].t = t_min;
            intersections[path_index].materialId = geoms[hit_geom_index].materialid;
            intersections[path_index].surfaceNormal = normal;
            intersections[path_index].outside = outside;
            if (depth == 0) {
                dev_normalImage[pathSegment.pixelIndex] = normal;
            }
        }
    }
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeMaterial(
    int iter,
    int num_paths,
    ShadeableIntersection* shadeableIntersections,
    PathSegment* pathSegments,
    Material* materials)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= num_paths) {
        return;
    }

    PathSegment& pathSegment = pathSegments[idx];

    if (idx < num_paths)
    {
        ShadeableIntersection intersection = shadeableIntersections[idx];
        if (intersection.t > 0.0f) // if the intersection exists...
        {
            // Set up the RNG
            // LOOK: this is how you use thrust's RNG! Please look at
            // makeSeededRandomEngine as well.
            thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, pathSegment.remainingBounces);
            thrust::uniform_real_distribution<float> u01(0, 1);

            Material material = materials[intersection.materialId];
            glm::vec3 materialColor = material.color;

            // If the material indicates that the object was a light, "light" the ray
            if (material.emittance > 0.0f) {
                pathSegment.color *= (materialColor * material.emittance);
                pathSegment.remainingBounces = 0;
            }
            // Otherwise, do some pseudo-lighting computation. This is actually more
            // like what you would expect from shading in a rasterizer like OpenGL.
            // TODO: replace this! you should be able to start with basically a one-liner
            else {
                glm::vec3 intersectPoint = getPointOnRay(pathSegment.ray, intersection.t);

                scatterRay(pathSegment, intersectPoint, intersection.surfaceNormal, material, rng);
                pathSegment.color *= material.color;
                pathSegment.remainingBounces--;

            }
            // If there was no intersection, color the ray black.
            // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
            // used for opacity, in which case they can indicate "no opacity".
            // This can be useful for post-processing and image compositing.
        }
        else {
            pathSegment.color = glm::vec3(0.0f);
            pathSegment.remainingBounces = 0;
        }
    }
}

// Collect the color from each terminated path before stream compaction
__global__ void gatherColor(int nPaths, glm::vec3* image, PathSegment* pathSegments)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;

    if (index < nPaths)
    {
        PathSegment pathSegment = pathSegments[index];
        if (pathSegment.remainingBounces <= 0) {

            glm::vec3 color = pathSegment.color;
            image[pathSegment.pixelIndex] += color;
        }
    }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;

    if (index < nPaths)
    {
        PathSegment iterationPath = iterationPaths[index];
        image[iterationPath.pixelIndex] += iterationPath.color;
    }
}

struct remainBounces {
    __host__ __device__ bool operator()(const PathSegment& path)
    {
        return path.remainingBounces <= 0;
    }
};

// Kernel to extract the material ID //
__global__ void fillMaterialKeys(int n,
    ShadeableIntersection* intersections,
    int* keys)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) keys[i] = intersections[i].materialId;
}

void runDenoiser(
    const std::vector<glm::vec3>& inputBuffer,
    const std::vector<glm::vec3>& normalImage,
    std::vector<glm::vec3>& outputBuffer,
    glm::ivec2 resolution,
    int totalPixels)
{
    // Initialize the OIDN device and configure
    oidn::DeviceRef oidnDevice = oidn::newDevice();
    oidnDevice.commit();

    // Allocate OIDN buffer for input (beauty and normal)
    oidn::BufferRef beautyBuffer = oidnDevice.newBuffer(totalPixels * 3 * sizeof(float));
    oidn::BufferRef normalBuffer = oidnDevice.newBuffer(totalPixels * 3 * sizeof(float));
    float* beautyData = static_cast<float*>(beautyBuffer.getData());
    float* normalData = static_cast<float*>(normalBuffer.getData());

    // Copy pixel data into OIDN buffer
    for (int px = 0; px < totalPixels; ++px) {
        beautyData[px * 3 + 0] = inputBuffer[px].x;
        beautyData[px * 3 + 1] = inputBuffer[px].y;
        beautyData[px * 3 + 2] = inputBuffer[px].z;
    }

    // Set up denoiser filter
    oidn::FilterRef denoiseFilter = oidnDevice.newFilter("RT");
    denoiseFilter.setImage("color", beautyBuffer, oidn::Format::Float3, resolution.x, resolution.y);
    denoiseFilter.setImage("normal", normalBuffer, oidn::Format::Float3, resolution.x, resolution.y);
    denoiseFilter.setImage("output", beautyBuffer, oidn::Format::Float3, resolution.x, resolution.y);
    denoiseFilter.set("hdr", true);
    denoiseFilter.commit();

    // Execute denoising
    denoiseFilter.execute();

    // Error check
    const char* oidnError = nullptr;
    if (oidnDevice.getError(oidnError) != oidn::Error::None) {
        std::cerr << "OIDN Denoiser Error: " << oidnError << std::endl;
    }

    // Copy denoised data back into the output vector
    beautyData = static_cast<float*>(beautyBuffer.getData());
    for (int px = 0; px < totalPixels; ++px) {
        outputBuffer[px] = glm::vec3(
            beautyData[px * 3 + 0],
            beautyData[px * 3 + 1],
            beautyData[px * 3 + 2]
        );
    }

    normalData = static_cast<float*>(normalBuffer.getData());
    for (int i = 0; i < totalPixels; ++i) {
        glm::vec3 normal = glm::normalize((normalImage)[i]);
        normalData[i * 3] = normal.x;
        normalData[i * 3 + 1] = normal.y;
        normalData[i * 3 + 2] = normal.z;
    }
}
/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter)
{
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera& cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    // 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
        (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
        (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // 1D block for path tracing
    const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * TODO: Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * TODO: Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally, add this iteration's results to the image. This has been done
    //   for you.

    // TODO: perform one iteration of path tracing

    generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
    checkCUDAError("generate camera ray");

    int depth = 0;
    PathSegment* dev_path_end = dev_paths + pixelcount;
    int num_paths = dev_path_end - dev_paths;

    // --- PathSegment Tracing Stage ---
    // Shoot ray into scene, bounce between objects, push shading chunks

    bool iterationComplete = false;

    while (!iterationComplete)
    {
        // clean shading chunks
        cudaMemset(dev_intersections, 0, num_paths * sizeof(ShadeableIntersection));

        // tracing
        dim3 numBlocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
        int vertexSize = hst_scene->vertices.size();

        computeIntersections << <numBlocksPathSegmentTracing, blockSize1d >> > (
            depth,
            num_paths,
            dev_paths,
            dev_geoms,
            hst_scene->geoms.size(),
            dev_intersections,
            dev_vertices,
            dev_normalImage
            );
        checkCUDAError("trace one bounce");
        cudaDeviceSynchronize();

        // Before shading, sort by material to increase memory coherency and reduce warp divergence.
#if     MATERIALSORT      
        fillMaterialKeys << <numBlocksPathSegmentTracing, blockSize1d >> > (
            num_paths,
            dev_intersections,
            dev_matKeys);
        cudaDeviceSynchronize();
        checkCUDAError("fillMaterialKeys");

        thrust::device_ptr<int> thrust_materalIds(dev_matKeys);
        thrust::device_ptr<PathSegment> thrust_pathSegments(dev_paths);
        thrust::device_ptr<ShadeableIntersection> thrust_intersections(dev_intersections);


        auto zippedBegin = thrust::make_zip_iterator(
            thrust::make_tuple(thrust_intersections,
                thrust_pathSegments));
        thrust::sort_by_key(thrust::device,
            thrust_materalIds,
            thrust_materalIds + num_paths,
            zippedBegin);
#endif

        // TODO:
        // --- Shading Stage ---
        // Shade path segments based on intersections and generate new rays by
        // evaluating the BSDF.
        // Start off with just a big kernel that handles all the different
        // materials you have in the scenefile.
        // TODO: compare between directly shading the path segments and shading
        // path segments that have been reshuffled to be contiguous in memory.

        // sort pathSegments and intersections by materialId


        shadeMaterial << <numBlocksPathSegmentTracing, blockSize1d >> > (
            iter,
            num_paths,
            dev_intersections,
            dev_paths,
            dev_materials
            );

        checkCUDAError("shadeMaterial");
        cudaDeviceSynchronize();

#if     STREAMCOMPACT
        gatherColor << <numBlocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_image, dev_paths);
        PathSegment* new_path_end = thrust::remove_if(thrust::device, dev_paths, dev_paths + num_paths, remainBounces());
        cudaDeviceSynchronize();

        num_paths = new_path_end - dev_paths;
        dev_path_end = new_path_end;
#endif

        if (guiData != NULL)
        {
            guiData->TracedDepth = depth;
        }

        if (num_paths <= 0) iterationComplete = true;

        depth++;

        if (depth == traceDepth)
            iterationComplete = true;
        // TODO: should be based off stream compaction results.
    }

    // Assemble this iteration and apply it to the image
    // finalGather << <numBlocksPathSegmentTracing, blockSize1d >> > (pixelcount, dev_image, dev_paths);
    // checkCUDAError("finalGather");

    // Assemble this iteration and apply it to the image
    dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
    finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);
    cudaDeviceSynchronize();

    ///////////////////////////////////////////////////////////////////////////
    cudaMemcpy(dev_denoised_image, dev_image, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);
#ifdef DENOISING
    // Transfer image data from GPU to CPU for denoising
    std::vector<glm::vec3> hostImage(pixelcount);
    std::vector<glm::vec3> hostImageDenoised(pixelcount);
    std::vector<glm::vec3> hostNormalImage(pixelcount);

    cudaMemcpy(hostImage.data(), dev_denoised_image, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();

    // copy for before/after comparison
    cudaMemcpy(hostImageDenoised.data(), dev_denoised_image, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
    // Normal buffer
    cudaMemcpy(hostNormalImage.data(), dev_normalImage, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    runDenoiser(hostImage, hostNormalImage, hostImageDenoised, cam.resolution, pixelcount);

    // Transfer denoised result back to GPU memory
    cudaMemcpy(dev_denoised_image, hostImageDenoised.data(), pixelcount * sizeof(glm::vec3), cudaMemcpyHostToDevice);
    cudaDeviceSynchronize();
#endif

    // Send results to OpenGL buffer for rendering
    sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_denoised_image);

    // Retrieve image from GPU
    if (iter != hst_scene->state.iterations) {
        cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
    }
    else {
        // Copy the denoised image to the host
        cudaMemcpy(hst_scene->state.image.data(), dev_denoised_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
    }
    checkCUDAError("pathtrace");
}
