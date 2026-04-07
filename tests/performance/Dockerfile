# Mixed workload benchmark — all 10 languages with resources + prompts
# Build context: zeromcp/
#
# Usage:
#   docker build -t zeromcp-mixed -f tests/performance/Dockerfile .
#   docker run --rm zeromcp-mixed

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tools
RUN apt-get update && apt-get install -y \
    curl wget git unzip zip build-essential procps \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs

# Python 3.12
RUN apt-get update && apt-get install -y python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Go
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://go.dev/dl/go1.22.5.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Ruby
RUN apt-get update && apt-get install -y ruby \
    && rm -rf /var/lib/apt/lists/*

# Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# PHP
RUN apt-get update && apt-get install -y php-cli \
    && rm -rf /var/lib/apt/lists/*

# .NET 8
RUN apt-get update && apt-get install -y dotnet-sdk-8.0 \
    && rm -rf /var/lib/apt/lists/*

# Java 21 + Gradle
RUN apt-get update && apt-get install -y openjdk-21-jdk maven \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://services.gradle.org/distributions/gradle-8.10-bin.zip -o /tmp/gradle.zip \
    && unzip /tmp/gradle.zip -d /opt && rm /tmp/gradle.zip
ENV PATH="/opt/gradle-8.10/bin:${PATH}"

# Swift
RUN apt-get update && apt-get install -y \
    binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
    libncurses5-dev pkg-config tzdata zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then SWIFT_ARCH="aarch64"; else SWIFT_ARCH="x86_64"; fi && \
    curl -fsSL "https://download.swift.org/swift-6.0.3-release/ubuntu2404-${SWIFT_ARCH}/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu24.04-${SWIFT_ARCH}.tar.gz" \
    | tar -C /usr/local --strip-components=2 -xz

WORKDIR /zeromcp
COPY . .

# Build Node
RUN cd nodejs && npm install && npm run build

# Build Go
RUN cd go && go build -o /usr/local/bin/zeromcp-go-resource ./examples/resource-test/

# Build Rust
RUN cd rust && cargo build --example resource_test --release

# Build Swift
RUN cd swift && rm -rf .build && swift build 2>&1; \
    test -f .build/debug/zeromcp-resource-test && cp .build/debug/zeromcp-resource-test /usr/local/bin/zeromcp-swift-resource || echo "Swift resource build failed"

# Build Java
RUN cd java && mvn package -q -DskipTests && \
    mvn dependency:copy-dependencies -DoutputDirectory=target/deps -q && \
    mkdir -p /tmp/java-out && \
    javac -cp "target/zeromcp-0.1.1.jar:target/deps/*" \
      -d /tmp/java-out src/main/java/ResourceTest.java 2>&1 || echo "Java build failed"

# Build Kotlin
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
RUN cd kotlin && gradle :example:installDist -x test 2>&1 | tail -5 || echo "Kotlin build failed"

# Build C#
RUN cd csharp && dotnet publish ResourceTest -c Release -o /tmp/csharp-resource-out 2>&1 | tail -3

# Benchmark harness
CMD ["node", "tests/performance/run-mixed-all.mjs"]
