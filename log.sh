#!/bin/bash

directory="/"
log_extension=".log"
error_log_filename="error_log"

while true; do
    find "$directory" -type f -name "$error_log_filename" -o -name "*$log_extension" -delete
    sleep 1
done
