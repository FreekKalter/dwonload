#!/bin/sh
plackup -E debug -R ~/dwonload/lib -s Starman --workers=10 -p 3000 -a bin/app.pl
