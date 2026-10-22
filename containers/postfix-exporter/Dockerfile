# kumina/postfix_exporter has no published image on any registry, and its
# own Dockerfile is broken today (golang:1.16's Debian base points at
# archived security.debian.org paths - confirmed by testing). So this
# clones and builds their source directly with a current, maintained
# golang base instead of vendoring a copy of their Go code.
FROM golang:1.23-bookworm AS builder
RUN apt-get update -qq && apt-get install -qqy build-essential libsystemd-dev
WORKDIR /src
RUN git clone --depth 1 https://github.com/kumina/postfix_exporter.git .
RUN go mod download && go mod verify
RUN go build -o /bin/postfix_exporter

FROM debian:bookworm-slim
EXPOSE 9154
COPY --from=builder /bin/postfix_exporter /bin/
ENTRYPOINT ["/bin/postfix_exporter"]
