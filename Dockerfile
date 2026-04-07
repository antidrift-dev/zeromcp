FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tools
RUN apt-get update && apt-get install -y \
    curl wget git unzip zip build-essential \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs

# Python 3.12
RUN apt-get update && apt-get install -y python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Go 1.22
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

# Java 21 + Gradle (for Kotlin)
RUN apt-get update && apt-get install -y openjdk-21-jdk maven \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://services.gradle.org/distributions/gradle-8.10-bin.zip -o /tmp/gradle.zip \
    && unzip /tmp/gradle.zip -d /opt \
    && rm /tmp/gradle.zip
ENV PATH="/opt/gradle-8.10/bin:${PATH}"

# Swift 6.0.3
RUN apt-get update && apt-get install -y \
    binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
    libncurses5-dev pkg-config tzdata zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then SWIFT_ARCH="aarch64"; else SWIFT_ARCH="x86_64"; fi && \
    curl -fsSL "https://download.swift.org/swift-6.0.3-release/ubuntu2404-${SWIFT_ARCH}/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu24.04-${SWIFT_ARCH}.tar.gz" \
    | tar -C /usr/local --strip-components=2 -xz
ENV PATH="/usr/local/bin:${PATH}"

WORKDIR /zeromcp
COPY . .

# Build Go
RUN cd go && go build -o /usr/local/bin/zeromcp-go ./examples/basic/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-sandbox ./examples/sandbox-test/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-creds ./examples/credential-test/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-chaos ./examples/chaos-test/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-timeout ./examples/timeout-test/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-bypass ./examples/bypass-test/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-cli ./cmd/zeromcp/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-advanced ./examples/advanced/
RUN cd go && go build -o /usr/local/bin/zeromcp-go-resource ./examples/resource-test/

# Build Rust
RUN cd rust && cargo build --example hello --example sandbox_test --example chaos_test --example timeout_test --example bypass_test --example credential_test --example resource_test --release

# Build Swift (clean build inside Linux container)
RUN cd swift && rm -rf .build && swift build 2>&1; \
    test -f .build/debug/zeromcp-example && cp .build/debug/zeromcp-example /usr/local/bin/zeromcp-swift || echo "Swift example build failed"; \
    test -f .build/debug/zeromcp-sandbox-test && cp .build/debug/zeromcp-sandbox-test /usr/local/bin/zeromcp-swift-sandbox || echo "Swift sandbox build failed"; \
    test -f .build/debug/zeromcp-chaos-test && cp .build/debug/zeromcp-chaos-test /usr/local/bin/zeromcp-swift-chaos || echo "Swift chaos build failed"; \
    test -f .build/debug/zeromcp-timeout-test && cp .build/debug/zeromcp-timeout-test /usr/local/bin/zeromcp-swift-timeout || echo "Swift timeout build failed"; \
    test -f .build/debug/zeromcp-bypass-test && cp .build/debug/zeromcp-bypass-test /usr/local/bin/zeromcp-swift-bypass || echo "Swift bypass build failed"; \
    test -f .build/debug/zeromcp-credential-test && cp .build/debug/zeromcp-credential-test /usr/local/bin/zeromcp-swift-creds || echo "Swift credential build failed"; \
    test -f .build/debug/zeromcp-resource-test && cp .build/debug/zeromcp-resource-test /usr/local/bin/zeromcp-swift-resource || echo "Swift resource build failed"

# Build Java — library with deps, then compile example
RUN cd java && mvn package -q -DskipTests && \
    mvn dependency:copy-dependencies -DoutputDirectory=target/deps -q && \
    mkdir -p /tmp/java-out && \
    javac -cp "target/zeromcp-0.1.1.jar:target/deps/*" \
      -d /tmp/java-out \
      example/src/main/java/Main.java \
      example/src/main/java/SandboxTest.java \
      example/src/main/java/ChaosTest.java \
      example/src/main/java/TimeoutTest.java \
      example/src/main/java/BypassTest.java \
      example/src/main/java/CredentialTest.java \
      src/main/java/ResourceTest.java 2>&1 || echo "Java example build failed"

# Build Kotlin — library + example distribution
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
RUN cd kotlin && gradle :example:installDist -x test 2>&1 | tail -5 || echo "Kotlin build failed"

# Build C# — publish self-contained
RUN cd csharp && dotnet publish Example -c Release -o /tmp/csharp-out 2>&1 | tail -3
RUN cd csharp && dotnet publish SandboxTest -c Release -o /tmp/csharp-sandbox-out 2>&1 | tail -3
RUN cd csharp && dotnet publish ChaosTest -c Release -o /tmp/csharp-chaos-out 2>&1 | tail -3
RUN cd csharp && dotnet publish TimeoutTest -c Release -o /tmp/csharp-timeout-out 2>&1 | tail -3
RUN cd csharp && dotnet publish BypassTest -c Release -o /tmp/csharp-bypass-out 2>&1 | tail -3
RUN cd csharp && dotnet publish CredentialTest -c Release -o /tmp/csharp-creds-out 2>&1 | tail -3
RUN cd csharp && dotnet publish ResourceTest -c Release -o /tmp/csharp-resource-out 2>&1 | tail -3

# Test fixtures
RUN echo '{"api_key":"file-secret-123"}' > /tmp/test-creds.json

CMD ["node", "tests/conformance/run-all.js"]
