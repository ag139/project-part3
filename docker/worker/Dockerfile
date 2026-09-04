FROM python:3.12-slim
WORKDIR /app

RUN groupadd -r appgroup && useradd -r -g appgroup -u 1000 appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chown -R appuser:appgroup /app

ARG APP_VERSION=unknown
ARG GIT_SHA=unknown
ARG RELEASE=unknown
ENV APP_VERSION=$APP_VERSION
ENV GIT_SHA=$GIT_SHA
ENV RELEASE=$RELEASE
ENV PYTHONUNBUFFERED=1
EXPOSE 9100
USER appuser

CMD ["python", "worker.py"]
