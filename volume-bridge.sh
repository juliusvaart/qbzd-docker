#!/bin/sh
# Drive the DAC's own ALSA mixer control from the daemon's volume.
#
# qbzd's hardware-volume path looks for conventionally named mixer elements
# (Master, PCM, Headphone, ...). USB DACs name their single control after the
# device instead — a Topping D50 III exposes 'D50 III' — so the lookup fails
# and the daemon logs "No volume control found". This bridge polls the volume
# the daemon reports and writes it to the real control, which keeps the audio
# path bit-perfect: attenuation happens in the DAC, not in software.
#
# Leave audio.alsa_hardware_volume enabled in the daemon. Its hardware attempt
# fails harmlessly and, crucially, it then applies no software scaling of its
# own — otherwise the two attenuations would multiply.
set -u

: "${ALSA_CARD:?set ALSA_CARD, e.g. III (see: aplay -L)}"
: "${ALSA_CONTROL:?set ALSA_CONTROL, e.g. 'D50 III' (see: amixer -c \$ALSA_CARD scontrols)}"

export QBZD_HOST="${QBZD_HOST:-qbzd:8182}"
interval="${POLL_INTERVAL:-0.25}"
last=""

echo "volume-bridge: $QBZD_HOST -> card $ALSA_CARD, control '$ALSA_CONTROL'"

while :; do
    # `qbzd volume` prints "vol 37%". Empty output means the daemon is not
    # answering yet (start-up, restart), so retry rather than exit.
    want=$(qbzd volume 2>/dev/null | tr -dc '0-9')

    if [ -n "$want" ] && [ "$want" != "$last" ]; then
        # -M uses the mapped (perceptual) scale, matching how volume sliders
        # are expected to behave rather than the raw register range.
        if amixer -q -M -c "$ALSA_CARD" set "$ALSA_CONTROL" "${want}%"; then
            last="$want"
        fi
    fi

    sleep "$interval"
done
