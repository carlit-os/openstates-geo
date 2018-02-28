#!/usr/bin/env bash

set -e

echo "Downloading TIGER/Line shapefiles"
./get-all-sld-shapefiles.py

echo "Additional shapefiles, such as New Hampshire floterials, should be downloaded here in the future"

echo "Unzip the shapefiles"
for f in ./data/*.zip; do
	# Catch cases where the ZIP file doesn't function, like DC SLDL
	unzip -q -o -d ./data "$f" || echo "Failed to unzip $f; this is probably a non-existant chamber"
done

echo "Convert to GeoJSON"
count=0
total="$(find ./data/tl_*.shp | wc -l | xargs)"
for f in ./data/tl_*.shp; do
	# OGR's GeoJSON driver cannot overwrite files, so make sure
	# the file doesn't already exist
	rm -f "${f}.geojson"
	ogr2ogr -f GeoJSON "${f}.geojson" "$f"

	echo -ne "    ${count} of ${total} shapefiles converted\\r"
	(( count++ ))
done

echo "Concatenate the shapefiles into one file"
# This should be the purview of `@mapbox/geojson-merge`,
# but that tool isn't working properly on this volume of files
echo '{ "type": "FeatureCollection", "features": [' > ./data/sld.geojson
cat ./data/tl_*.geojson >> ./data/sld.geojson
sed -i '' '/^{$/d' ./data/sld.geojson
sed -i '' '/^}$/d' ./data/sld.geojson
sed -i '' '/^"type": "FeatureCollection",$/d' ./data/sld.geojson
sed -i '' '/^"features": \[$/d' ./data/sld.geojson
sed -i '' '/^\]$/d' ./data/sld.geojson
# Now, all lines are GeoJSON Feature objects
# Make sure all of them have trailing commas, except for the last
sed -i '' 's/,$//g' ./data/sld.geojson
sed -i '' 's/}$/},/g' ./data/sld.geojson
# Strip empty lines
# The macOS Homebrew sed `/d` fails to do this, and it doesn't hurt on
# other *nix platforms
awk 'NF' ./data/sld.geojson > ./data/tmp.txt
mv ./data/tmp.txt ./data/sld.geojson
echo ']}' >> ./data/sld.geojson

echo "Clip districts to the coastline and Great Lakes"
curl --silent --output ./data/cb_2016_us_nation_5m.zip https://www2.census.gov/geo/tiger/GENZ2016/shp/cb_2016_us_nation_5m.zip
unzip -q -o -d ./data ./data/cb_2016_us_nation_5m.zip
# Ensure that the output file doesn't already exist
rm -f ./data/sld-clipped.geojson
# Water-only placeholder areas end in `ZZZ`
ogr2ogr \
	-clipsrc ./data/cb_2016_us_nation_5m.shp \
	-where "GEOID NOT LIKE '%ZZZ'" \
	-f GeoJSON \
	./data/sld-clipped.geojson \
	./data/sld.geojson

echo "Join the OCD division IDs to the GeoJSON"
curl --silent --output ./data/sldu-ocdid.csv https://raw.githubusercontent.com/opencivicdata/ocd-division-ids/master/identifiers/country-us/census_autogenerated_14/us_sldu.csv
curl --silent --output ./data/sldl-ocdid.csv https://raw.githubusercontent.com/opencivicdata/ocd-division-ids/master/identifiers/country-us/census_autogenerated_14/us_sldl.csv
./join-ocd-division-ids.js

echo "Convert the GeoJSON into MBTiles for serving"
tippecanoe \
	--layer sld \
	--minimum-zoom 2 --maximum-zoom 13 \
	--detect-shared-borders \
	--simplification 10 \
	--force --output ./data/sld.mbtiles \
	./data/sld-with-ocdid.geojson

if [ -z ${MAPBOX_ACCOUNT+x} ] || [ -z ${MAPBOX_ACCESS_TOKEN+x} ] ; then
	echo "Skipping upload step; MAPBOX_ACCOUNT and/or MAPBOX_ACCESS_TOKEN not set in environment"
else
	echo "Upload the MBTiles to Mapbox, for serving"
	mapbox upload "${MAPBOX_ACCOUNT}.sld" ./data/sld.mbtiles
fi
