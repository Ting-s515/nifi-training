FROM apache/nifi:2.9.0

USER root

ADD requirements.txt /tmp/project/

ENV VIRTUAL_ENV=/opt/nifi/python
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        vim && \
    python3 -m venv "${VIRTUAL_ENV}" && \
    pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /tmp/project/requirements.txt && \
    rm -rf \
        /tmp/* \
        /var/lib/apt/lists/*
