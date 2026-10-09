# docker build -t astralstack linuxversion
# docker run --rm -v /path/to/frames:/data astralstack /data
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml README.md ./
COPY astralstack ./astralstack
RUN pip install --no-cache-dir ".[fits,fast]"
ENTRYPOINT ["astralstack"]
