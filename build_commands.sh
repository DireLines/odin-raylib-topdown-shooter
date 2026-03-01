#!/bin/bash

#basic
odin run .

#release
odin run . -o:speed

#performance troubleshooting
odin build . -define:timing_logs=true -o:speed && ./odin-raylib | loghist

#memory troubleshooting
odin run . -define:track_allocations=true
