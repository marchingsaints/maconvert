FFmpeg 9.0.2, LGPL 2.1+ build (no GPL parts), arm64, statically linked with libvpx and libopus.
Rebuilt from Homebrew's verified source tarball with:

    ./configure --enable-static --disable-shared --disable-doc --disable-ffplay --disable-ffprobe --disable-network \
      --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-libvpx --enable-libopus

Shipped as a separate executable inside the app, which keeps LGPL compliance simple.
