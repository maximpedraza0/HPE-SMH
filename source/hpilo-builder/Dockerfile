FROM debian:bookworm-slim

ARG KERNEL_VERSION

RUN apt-get update && apt-get install -y \
    wget xz-utils patch make gcc bc \
    flex bison libssl-dev libelf-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz \
    && tar xf linux-${KERNEL_VERSION}.tar.xz \
    && rm linux-${KERNEL_VERSION}.tar.xz

WORKDIR /build/linux-${KERNEL_VERSION}

COPY unraid-src/ /unraid-src/

RUN cp /unraid-src/.config .config && \
    for p in /unraid-src/*.patch; do \
        echo "Applying $p..."; \
        patch -p1 < "$p" || echo "WARN: $p failed"; \
    done

RUN make olddefconfig && make modules_prepare

RUN mkdir -p /build/hpilo-build && \
    cp drivers/misc/hpilo.c /build/hpilo-build/ && \
    cp drivers/misc/hpilo.h /build/hpilo-build/ && \
    echo 'obj-m += hpilo.o' > /build/hpilo-build/Makefile && \
    make -C /build/linux-${KERNEL_VERSION} M=/build/hpilo-build \
        KBUILD_MODPOST_WARN=1 modules

RUN mkdir -p /output && \
    cp /build/hpilo-build/hpilo.ko /output/
