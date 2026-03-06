#!/bin/bash

FFMPEG=/opt/ffmpeg-rk/bin/ffmpeg
VIDEO=test_low.mp4
SERVER=rtsp://127.0.0.1/live

PIDS_FILE=ffmpeg_pids.txt

start_streams() {
    echo "Starting 4 streams..."

    for i in 1 2 3 4
    do
        $FFMPEG -re -stream_loop -1 -i $VIDEO \
        -c copy \
        -f rtsp ${SERVER}/cam0${i} \
        > cam0${i}.log 2>&1 &

        echo $! >> $PIDS_FILE
        echo "Started cam0${i} PID=$!"
    done

    echo "All streams started."
}

stop_streams() {
    if [ -f $PIDS_FILE ]; then
        echo "Stopping streams..."
        while read pid; do
            kill -9 $pid 2>/dev/null
        done < $PIDS_FILE
        rm -f $PIDS_FILE
        echo "All streams stopped."
    else
        echo "No running streams found."
    fi
}

case "$1" in
    start)
        start_streams
        ;;
    stop)
        stop_streams
        ;;
    restart)
        stop_streams
        sleep 1
        start_streams
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        ;;
esac

