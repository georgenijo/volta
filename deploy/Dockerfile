FROM oven/bun:1.4.1 AS dependencies
WORKDIR /app
COPY server/package.json server/bun.lock ./
RUN bun install --frozen-lockfile --production

FROM oven/bun:1.4.1
WORKDIR /app
COPY --from=dependencies --chown=bun:bun /app/node_modules ./node_modules
COPY --chown=bun:bun server/package.json ./
COPY --chown=bun:bun server/src ./src
USER bun
ENV HOST=0.0.0.0 PORT=8080
EXPOSE 8080
CMD ["bun", "src/index.ts"]
