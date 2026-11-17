FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN pip install pyarrow==26.0.0 boto3==1.43.116

WORKDIR /app
COPY lab/ lab/

ENTRYPOINT ["python", "-m", "lab.kube"]
