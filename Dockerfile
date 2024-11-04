# syntax=docker/dockerfile:1
ARG UID=1001
ARG VERSION=EDGE
ARG RELEASE=0

ARG CACHE_HOME=/.cache
ARG TORCH_HOME=${CACHE_HOME}/torch
ARG HF_HOME=${CACHE_HOME}/huggingface

# Skip requirements installation for final stage and will install them in the first startup.
# This reduce the image size to 1.27G but increase the first startup time.
ARG SKIP_REQUIREMENTS_INSTALL=

########################################
# Base stage
########################################
FROM --platform=linux/amd64 python:3.10-slim as base

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

ENV PIP_USER="true"

# Install runtime/buildtime dependencies
RUN --mount=type=cache,id=apt-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/apt \
    --mount=type=cache,id=aptlists-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/lib/apt/lists \
    apt-get update && apt-get install -y --no-install-recommends \
    # Install Pillow dependencies explicitly
    # https://pillow.readthedocs.io/en/stable/installation/building-from-source.html
    libjpeg62-turbo-dev libwebp-dev zlib1g-dev \
    libgl1 libglib2.0-0 libgoogle-perftools-dev \
    git libglfw3-dev libgles2-mesa-dev pkg-config libcairo2 build-essential wget \
    libvulkan1 

########################################
# Build stage
########################################
FROM --platform=linux/amd64 base as prepare_build_empty

# An empty directory for final stage
RUN install -d /root/.local

FROM --platform=linux/amd64 base as prepare_build

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /source

# Install under /root/.local
ARG PIP_NO_WARN_SCRIPT_LOCATION=0
ARG PIP_ROOT_USER_ACTION="ignore"
ARG PIP_NO_COMPILE="true"
ARG PIP_DISABLE_PIP_VERSION_CHECK="true"

# Copy requirements files
COPY requirements.txt /requirements.txt
RUN git clone --depth=1 https://github.com/lllyasviel/stable-diffusion-webui-forge /app && \
    chown -R $UID:0 /app && \
    chmod -R 775 /app
# Install all packages in build stage
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    pip install -U --force-reinstall pip setuptools==69.5.1 wheel && \
    pip install -U --extra-index-url https://download.pytorch.org/whl/cu121 --extra-index-url https://pypi.nvidia.com \
    torch==2.3.1 torchvision==0.18.1 xformers==0.0.27 && \
    pip install -r /requirements.txt && \
    pip install -r /app/requirements_versions.txt clip-anytorch

# Replace pillow with pillow-simd (Only for x86)
ARG TARGETPLATFORM
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
    CC="cc -mavx2" pip install -U --force-reinstall pillow-simd; \
    fi

# Cleanup
RUN find "/root/.local" -name '*.pyc' -print0 | xargs -0 rm -f || true ; \
    find "/root/.local" -type d -name '__pycache__' -print0 | xargs -0 rm -rf || true ;

# Select the build stage by the build argument
FROM --platform=linux/amd64 prepare_build${SKIP_REQUIREMENTS_INSTALL:+_empty} as build

########################################
# Final stage
########################################
FROM --platform=linux/amd64 base as final

ENV NVIDIA_VISIBLE_DEVICES all
ENV NVIDIA_DRIVER_CAPABILITIES compute,utility

# Fix missing libnvinfer7
RUN ln -s /usr/lib/x86_64-linux-gnu/libnvinfer.so /usr/lib/x86_64-linux-gnu/libnvinfer.so.7 && \
    ln -s /usr/lib/x86_64-linux-gnu/libnvinfer_plugin.so /usr/lib/x86_64-linux-gnu/libnvinfer_plugin.so.7

# Create user
ARG UID
RUN groupadd -g $UID $UID && \
    useradd -l -u $UID -g $UID -m -s /bin/sh -N $UID

ARG CACHE_HOME
ARG TORCH_HOME
ARG HF_HOME
ARG HF_TOKEN
ENV XDG_CACHE_HOME=${CACHE_HOME}
ENV TORCH_HOME=${TORCH_HOME}
ENV HF_HOME=${HF_HOME}
ENV HF_TOKEN=${HF_TOKEN}
# Create directories with correct permissions
RUN install -d -m 775 -o $UID -g 0 ${CACHE_HOME} && \
    install -d -m 775 -o $UID -g 0 /licenses && \
    install -d -m 775 -o $UID -g 0 /data && \
    # For arbitrary uid support
    install -d -m 775 -o $UID -g 0 /.local && \
    install -d -m 775 -o $UID -g 0 /.config && \
    chown -R $UID:0 /home/$UID && chmod -R g=u /home/$UID

# Combine all data operations into a single layer
COPY --chown=$UID:0 --chmod=775 ./data /data 

#Download Models
RUN mkdir -p data/models/Stable-diffusion/Flux
RUN mkdir -p data/models/VAE
RUN mkdir -p data/models/Deforum
# Download Models only if they do not already exist
RUN export HF_TOKEN=${HF_TOKEN} \
    && if [ ! -f "data/models/Stable-diffusion/Flux/flux1-dev-bnb-nf4-v2.safetensors" ]; then \
        wget --header="Authorization: Bearer $HF_TOKEN" -O data/models/Stable-diffusion/Flux/flux1-dev-bnb-nf4-v2.safetensors https://huggingface.co/lllyasviel/flux1-dev-bnb-nf4/resolve/main/flux1-dev-bnb-nf4-v2.safetensors; \
    fi \
    && if [ ! -f "data/models/VAE/ae.safetensors" ]; then \
        wget --header="Authorization: Bearer $HF_TOKEN" -O data/models/VAE/ae.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors; \
    fi \
    && if [ ! -f "data/models/VAE/clip_l.safetensors" ]; then \
        wget --header="Authorization: Bearer $HF_TOKEN" -O data/models/VAE/clip_l.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors; \
    fi \
    && if [ ! -f "data/models/VAE/t5xxl_fp16.safetensors" ]; then \
        wget --header="Authorization: Bearer $HF_TOKEN" -O data/models/VAE/t5xxl_fp16.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors; \
    fi \
    && if [ ! -f "data/models/Deforum/dpt_large-midas-2f21e586.pt" ]; then \
        wget --header="Authorization: Bearer $HF_TOKEN" -O data/models/Deforum/dpt_large-midas-2f21e586.pt https://huggingface.co/deforum/MiDaS/resolve/main/dpt_large-midas-2f21e586.pt; \
    fi

# curl for healthcheck
COPY --link --from=ghcr.io/tarampampam/curl:8.7.1 /bin/curl /usr/local/bin/

# ffmpeg
COPY --link --from=ghcr.io/jim60105/static-ffmpeg-upx:7.0-1 /ffmpeg /usr/local/bin/
COPY --link --from=ghcr.io/jim60105/static-ffmpeg-upx:7.0-1 /ffprobe /usr/local/bin/

# dumb-init
COPY --link --from=ghcr.io/jim60105/static-ffmpeg-upx:7.0-1 /dumb-init /usr/bin/

# Copy entrypoint and scripts
COPY --link --chown=$UID:0 --chmod=775 entrypoint.sh /entrypoint.sh
COPY --link --chown=$UID:0 --chmod=775 run.py /run.py
COPY --link --chown=$UID:0 --chmod=775 aws_ingest.py /aws_ingest.py

# Clone the stable-diffusion-webui-forge repository directly into /app
RUN git clone --depth=1 https://github.com/lllyasviel/stable-diffusion-webui-forge /app && \
    chown -R $UID:0 /app && \
    chmod -R 775 /app

RUN mkdir -p data/extensions/sd-forge-deforum && \
    git clone --depth=1 https://github.com/Tok/sd-forge-deforum.git data/extensions/sd-forge-deforum

# Copy installed packages from build stage
COPY --from=build /root/.local /home/$UID/.local
RUN chown -R $UID:0 /home/$UID/.local && chmod -R g=u /home/$UID/.local

ENV PATH="/app:/home/$UID/.local/bin:$PATH"
ENV PYTHONPATH="/app:/home/$UID/.local/lib/python3.10/site-packages:$PYTHONPATH"
ENV LD_PRELOAD=libtcmalloc.so

ENV GIT_CONFIG_COUNT=1
ENV GIT_CONFIG_KEY_0="safe.directory"
ENV GIT_CONFIG_VALUE_0="*"

WORKDIR /app

VOLUME [ "/tmp" ]

EXPOSE 7860

USER $UID

STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=2s --start-period=30s \
    CMD [ "curl", "--fail", "http://localhost:7860/" ]

# Use dumb-init as PID 1 to handle signals properly
ENTRYPOINT [ "dumb-init", "--", "/entrypoint.sh" ]

CMD [ "--xformers", "--api", "--allow-code" ]

ARG VERSION
ARG RELEASE
LABEL name="jim60105/docker-stable-diffusion-webui" \
    vendor="AUTOMATIC1111" \
    maintainer="jim60105" \
    url="https://github.com/jim60105/docker-stable-diffusion-webui" \
    version=${VERSION} \
    release=${RELEASE} \
    io.k8s.display-name="stable-diffusion-webui" \
    summary="Stable Diffusion web UI: A web interface for Stable Diffusion, implemented using Gradio library." \
    description="Stable Diffusion web UI: A web interface for Stable Diffusion, implemented using Gradio library. This is the docker image for AUTOMATIC1111's stable-diffusion-webui. For more information about this tool, please visit the following website: https://github.com/AUTOMATIC1111/stable-diffusion-webui."