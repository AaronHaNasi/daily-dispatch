FROM debian:bookworm-slim

# Calibre's own docs recommend the official installer over distro apt packages
# (often stale/buggy). ebook-convert still uses Qt under the hood even for
# headless CLI conversion, so the xcb/fontconfig libs below are required even
# though there's no display.
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget \
        xz-utils \
        ca-certificates \
        python3 \
        python3-pip \
        libxcb-cursor0 \
        libxcb-xinerama0 \
        libxcb-icccm4 \
        libxcb-image0 \
        libxcb-keysyms1 \
        libxcb-render-util0 \
        libxcb-randr0 \
        libfontconfig1 \
        libxrender1 \
        fonts-liberation \
        libegl1 \
        libopengl0 \
    && rm -rf /var/lib/apt/lists/*

# Pin explicitly for reproducible builds; bump deliberately, not "latest".
RUN wget -nv -O- https://download.calibre-ebook.com/linux-installer.sh | \
    sh /dev/stdin version=9.8.0

ENV QT_QPA_PLATFORM=offscreen

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

COPY daily-digest.recipe generate-dispatch.py ./

ENTRYPOINT ["python3", "generate-dispatch.py"]
