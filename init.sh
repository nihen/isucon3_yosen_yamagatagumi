wget -O /dev/null -q '127.0.0.1:5000/init'
wget -O /dev/null -q '127.0.0.1/'
wget -O /dev/null -q '127.0.0.1/signin'
(for s in `seq 1 210`; do wget -O /dev/null -q 127.0.0.1/recent/$s ;done)
