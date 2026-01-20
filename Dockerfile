FROM ghcr.io/foundry-rs/foundry:stable

WORKDIR /app

USER root

# Install Bun.
ENV BUN_INSTALL=/usr/local
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates unzip \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://bun.com/install | bash -s "bun-v1.3.0"

# Ensure the RPC cache directory is owned by the runtime user so the mounted volume stays writable.
RUN mkdir -p /home/foundry/.foundry/cache/rpc \
    && chown -R foundry:foundry /home/foundry/.foundry

USER foundry

# Copy the Foundry project files.
COPY package.json bun.lock ./
COPY foundry.toml remappings.txt ./
COPY src ./src
COPY lib ./lib
COPY script ./script

# Compile the contracts.
RUN forge clean && forge build

EXPOSE 8545

ENTRYPOINT ["bun"]
CMD ["run", "start"]
