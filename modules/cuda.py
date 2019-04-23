import re

# shamelessly copied and modified from nvidia's dockerfiles on gitlab!
GPGKEY_SUM="d1be581509378368edeec8c1eb2958702feedf3bc3d17011adbf24efacce4ab5"
GPGKEY_FPR="ae09fe4bbd223a84b2ccfce3f60f4b3d7fa2af80"


def emitHeader(writer):
    writer.emit("""LABEL maintainer="NVIDIA CORPORATION <cudatools@nvidia.com>"
RUN apt-key adv --fetch-keys "http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1604/x86_64/7fa2af80.pub" && \\
    apt-key adv --export --no-emit-version -a $NVIDIA_GPGKEY_FPR | tail -n +5 > cudasign.pub && \\
    echo "$NVIDIA_GPGKEY_SUM  cudasign.pub" | sha256sum -c --strict - && rm cudasign.pub && \\
    echo "deb http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1604/x86_64 /" > /etc/apt/sources.list.d/cuda.list && \\
    echo "deb http://developer.download.nvidia.com/compute/machine-learning/repos/ubuntu1604/x86_64 /" > /etc/apt/sources.list.d/nvidia-ml.list""",
         NVIDIA_GPGKEY_SUM=GPGKEY_SUM,
         NVIDIA_GPGKEY_FPR=GPGKEY_FPR)


def shortVersion(cudaVersionFull):
    # 9.0.170
    versionRegex = re.compile(r"^(\d+)[.](\d+)[.](\d+)$")
    match = versionRegex.search(cudaVersionFull)
    if match is None:
        raise Exception("Bad cudaVersionFull passed! [%s]" % cudaVersionFull)
    major = match.group(1)
    minor = match.group(2)
    versionShort = "%s.%s" % (major, minor)
    return major, minor, versionShort


def emit(writer, cudaVersionFull):
    major, minor, versionShort = shortVersion(cudaVersionFull)
    pkgVersion = "%s-%s=%s-1" % (major, minor, cudaVersionFull)
    emitHeader(writer)
    writer.emit("ENV CUDA_VERSION $cudaVersionFull", cudaVersionFull=cudaVersionFull)
    writer.packages(["cuda-cublas-$pkgVersion",
                     "cuda-cudart-$pkgVersion",
                     "cuda-cufft-$pkgVersion",
                     "cuda-curand-$pkgVersion",
                     "cuda-cusolver-$pkgVersion",
                     "cuda-cusparse-$pkgVersion",
                     "cuda-npp-$pkgVersion",
                     "cuda-nvgraph-$pkgVersion",
                     "cuda-nvrtc-$pkgVersion"],
                    pkgVersion=pkgVersion)
    writer.emit("RUN ln -s cuda-$versionShort /usr/local/cuda""", versionShort=versionShort)
    writer.emit("""RUN echo "/usr/local/cuda/lib64" >> /etc/ld.so.conf.d/cuda.conf && \\
    echo "/usr/local/nvidia/lib" >> /etc/ld.so.conf.d/nvidia.conf && \\
    echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf && \\
    ldconfig
ENV PATH /usr/local/nvidia/bin:/usr/local/cuda/bin:$${PATH}
ENV LD_LIBRARY_PATH /usr/local/nvidia/lib:/usr/local/nvidia/lib64:$${LD_LIBRARY_PATH}
ENV LIBRARY_PATH /usr/local/cuda/lib64/stubs:$${LIBRARY_PATH}
ENV CUDA_VERSION_SHORT $versionShort

LABEL com.nvidia.volumes.needed="nvidia_driver"
LABEL com.nvidia.cuda.version="$cudaVersionFull"

ENV NVIDIA_VISIBLE_DEVICES all
ENV NVIDIA_DRIVER_CAPABILITIES compute,utility
ENV NVIDIA_REQUIRE_CUDA "cuda>=$versionShort"
""",
         cudaVersionFull=cudaVersionFull,
         versionShort=versionShort)
