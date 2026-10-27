# Pinned versions first: package .mk files expand them at $(eval) time.
include $(BR2_EXTERNAL_EROSQ_PATH)/pins.mk
include $(sort $(wildcard $(BR2_EXTERNAL_EROSQ_PATH)/package/*/*.mk))

# MPD: compile out asserts (meson b_ndebug defaults false even for release
# buildtype). Without this, mpd ABORTS mid-BT-playback: the ALSA silence-timer
# fires just after the bluealsa output deactivates and trips `assert(active)`
# in AlsaOutputPlugin.cxx OnSilenceTimer — a benign race that NDEBUG/production
# builds run through fine. Was hand-patched in the build dir 2026-07-02 (lost
# on `make clean`); this is the durable fix. Works from external.mk because
# pkg-meson.mk expands $(PKG)_CONF_OPTS deferred, at recipe time.
MPD_CONF_OPTS += -Db_ndebug=true

# Memory pass 2026-10 (mempass-libs): compile out MPD features this device never
# uses. Every linked .so costs private dirty pages in mpd (GOT/relro/.data fixups;
# musl binds everything at load), and libvorbisenc alone was 52 kB dirty — it is
# only linked for the vorbis ENCODER (recorder/httpd outputs, unused; the vorbis
# DECODER needs only libvorbis). dbus/udisks: removable-media storage plugin, never
# configured. expat: xspf/asx/rss playlist parsers (playlists here are .m3u).
# pcre: `=~` regex filters (erosq-ui only uses exact find/list/search).
# recorder/fifo/pipe outputs + wave encoder: not in mpd.conf.
MPD_CONF_OPTS += -Ddbus=disabled -Dudisks=disabled -Dexpat=disabled \
	-Dpcre=disabled -Dvorbisenc=disabled -Drecorder=false -Dfifo=false \
	-Dpipe=false -Dwave_encoder=false

# Perf pass 2026-10 (perfpass-libs): audio decoders at -O2 instead of -Os.
# BR2_OPTIMIZE_S lands AFTER each package's own -O flags, so it silently
# overrode flac's -O3 and mpg123's -O2.  Decode-only bench on the X1000
# (City of Ocala, 209 s 16/44.1 FLAC, user CPU, 3 reps each):
#   libFLAC  -Os 4.54-4.65 s -> -O2 3.34-3.45 s (-27%), .so size unchanged.
# Appended after TARGET_CFLAGS so this -O2 wins over the -Os in it.
FLAC_CONF_ENV += CFLAGS="$(TARGET_CFLAGS) -O2 -fno-unroll-loops"

# mpg123 (MP3, i.e. podcasts): the integer decoder.  MPD only ever asks
# libmpg123 for signed 16-bit (Mpg123DecoderPlugin.cxx), so the float
# synth buys nothing, and on the X1000 the fixed-point build is much
# cheaper: 300 s of 44.1 kHz stereo MP3, user CPU, 3 reps each:
#   generic_fpu -Os 16.37-16.46 s, -O2 15.28-15.44 s,
#   generic_nofpu -O2 10.98-11.29 s (-32%).
# Output vs the float build: max |diff| 1 LSB, 2.8% of samples differ,
# 85.7 dB SNR (16-bit quantisation level).  Later --with-cpu wins.
MPG123_CONF_OPTS += --with-cpu=generic_nofpu
MPG123_CONF_ENV += CFLAGS="$(TARGET_CFLAGS) -O2 -fno-unroll-loops -fno-unroll-all-loops"

# libldac (bluealsa's LDAC encoder) at -O2: Buildroot's cmake toolchain file
# appends CMAKE_C_FLAGS_RELEASE after the -Os in CMAKE_C_FLAGS, so this wins.
# Encode bench (60 s 44.1/16 stereo, EQMID HQ, user CPU, 3 reps):
#   -Os 4.713-4.727 s -> -O2 4.115-4.121 s (-13%); bitstream byte-identical.
LIBLDAC_CONF_OPTS += -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG"
