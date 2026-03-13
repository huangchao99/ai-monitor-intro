sudo /opt/ffmpeg-rk/bin/ffmpeg -i test.mov \
-c:v h264_rkmpp \
-b:v 2M \
-s 1280x720 \
-g 60 \
-c:a aac -b:a 96k \
test_low.mp4
