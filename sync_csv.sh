#!/bin/bash
#
# Usage:
#
#   ./sync_csv.sh [mobile_][Mon_D_YYYY]
#
# Examples:
#
#   ./sync_csv.sh mobile_Dec_15_2018
#   ./sync_csv.sh Jan_1_2019

DATA=$HOME/archive
BASE=`pwd`

if [ -n "$1" ]; then
  archive=$1
  if [[ $archive == *mobile* ]]; then
    mobile=1
    adate=${archive#mobile_}
  else
    mobile=0
    adate=$archive
  fi
  echo "Processing $adate, mobile: $mobile, archive: $archive"

else
  echo "Must provide date, eg. Apr_15_2013"
  exit
fi

mkdir -p $DATA/processed/$archive

cd $DATA

if [ ! -f httparchive_${archive}_pages.csv.gz ]; then
  echo -e "Downloading data for $archive"
  gsutil cp "gs://httparchive/downloads/httparchive_${archive}_pages.csv.gz" ./
  if [ $? -ne 0 ]; then
    echo "Pages data for ${adate} is missing, exiting"
    exit
  fi
else
  echo -e "Pages data already downloaded for $archive, skipping."
fi

if [ ! -f httparchive_${archive}_requests.csv.gz ]; then
  gsutil cp "gs://httparchive/downloads/httparchive_${archive}_requests.csv.gz" ./
  if [ $? -ne 0 ]; then
    echo "Request data for ${adate} is missing, exiting"
    exit
  fi
else
  echo -e "Request data already downloaded for $archive, skipping."
fi

if [ ! -f processed/${archive}/pages.csv.gz ]; then
  echo -e "Converting pages data"
  gunzip -c "httparchive_${archive}_pages.csv.gz" \
  | sed -e 's/\\N,/"",/g' -e 's/\\N$/""/g' -e's/\([^\]\)\\"/\1""/g' -e's/\([^\]\)\\"/\1""/g' -e 's/\\"","/\\\\","/g' \
  | gzip > "processed/${archive}/pages.csv.gz"
else
  echo -e "Pages data already converted, skipping."
fi

if ls processed/${archive}/requests_* &> /dev/null; then
  echo -e "Request data already converted, skipping."
else
  echo -e "Converting requests data"
  gunzip -c "httparchive_${archive}_requests.csv.gz" \
	| sed -e 's/\\N,/"",/g' -e 's/\\N$/""/g' -e 's/\\"/""/g' -e 's/\\"","/\\\\","/g' \
  | python fixcsv.py \
	| split --lines=8000000 --filter='pigz - > $FILE.gz' - processed/$archive/requests_
fi

cd processed/${archive}

table=$(date --date="$(echo $adate | sed "s/_/ /g" -)" "+%Y_%m_%d")
ptable="summary_pages.${table}"
rtable="summary_requests.${table}"

echo -e "Syncing data to Google Storage"
gsutil cp -n * gs://httparchive/${archive}/

if [[ $mobile == 1 ]]; then
  ptable="${ptable}_mobile"
  rtable="${rtable}_mobile"
else
  ptable="${ptable}_desktop"
  rtable="${rtable}_desktop"
fi

bq show httparchive:${ptable} &> /dev/null
if [ $? -ne 0 ]; then
  echo -e "Submitting new pages import ${ptable} to BigQuery"
  bq load --max_bad_records 10 --replace $ptable gs://httparchive/${archive}/pages.csv.gz $BASE/schema/pages.json
else
  echo -e "${ptable} already exists, skipping."
fi

bq show httparchive:${rtable} &> /dev/null
if [ $? -ne 0 ]; then
  echo -e "Submitting new requests import ${rtable} to BigQuery"
  bq load --max_bad_records 10 --replace $rtable gs://httparchive/${archive}/requests_* $BASE/schema/requests.json
else
  echo -e "${rtable} already exists, skipping."
fi

echo -e "Attempting to generate reports..."
cd $HOME/code

gsutil -q stat gs://httparchive/reports/$table/*
if [ $? -eq 1 ]; then
  . sql/generate_reports.sh -fth $table
  ls -1 sql/lens | xargs -I lens sql/generate_reports.sh -fth $table -l lens
else
  echo -e "Reports for ${table} already exist, skipping."
fi

echo "Done"
