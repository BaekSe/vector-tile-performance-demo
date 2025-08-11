# Vector Tile Performance Demo

## 📋 Project Overview
A performance demonstration and comparison of vector tile technologies for massive geospatial datasets. Showcases Martin + PostGIS handling up to 100 million polygons with vector vs raster tile optimization strategies.

### 🏗️ Tech Stack
- **Vector Tile Server**: Martin (Rust-based)
- **Database**: PostGIS (PostgreSQL + spatial extensions)
- **Frontend**: OpenLayers
- **Proxy**: Nginx (caching & CORS)
- **Data**: OpenStreetMap PBF data

### 📈 Performance Features
- **Vector Tiles**: Real-time processing up to ~200k polygons
- **Raster Tiles**: PNG rendering support for 100M+ polygons
- **Pre-generation**: Batch processing for massive datasets

## 🚀 Quick Start

### 1. Prerequisites
```bash
# macOS (Homebrew)
brew install docker docker-compose

# Ubuntu/Debian
sudo apt update
sudo apt install docker.io docker-compose-plugin

# Windows: Install Docker Desktop
```

### 2. Run Project
```bash
# Clone repository
git clone <repository-url>
cd martin-prac

# Start Docker containers
docker-compose up -d

# Check status
docker-compose ps
```

### 3. Access Web Interface
- **Main Page**: http://localhost:8080
- **Martin API**: http://localhost:3000
- **PostGIS**: localhost:5432 (martin_user/martin_password)

## 🗄️ Data Loading

### Download PBF Data
```bash
# Seoul data example (for quick testing)
wget -P dataset/ https://download.geofabrik.de/asia/south-korea-latest.osm.pbf

# Or full Korea data
wget -P dataset/ https://download.geofabrik.de/asia/south-korea-latest.osm.pbf
```

### Load Data
```bash
# Run loading script
./load-data.sh

# Loading takes about 5-10 minutes (Seoul data)
```

## 📁 Project Structure
```
martin-prac/
├── README.md                   # 📖 This file
├── docker-compose.yml          # 🐳 Docker services definition
├── martin-config.yaml          # ⚙️ Martin configuration
├── nginx.conf                  # 🌐 Nginx proxy settings
├── load-data.sh               # 💾 Data loading script
├── init-db/                    # 🗄️ PostGIS initialization SQL
│   ├── 01-create-tables.sql
│   ├── 16-dense-sampling-raster.sql  # Raster function
│   └── ...
├── web/                        # 🖥️ Frontend files
│   └── index.html
├── scripts/                    # 📝 Tile generation scripts
│   ├── generate_tiles.py       # Python (high-performance)
│   ├── generate-tiles.sh       # Bash
│   └── requirements.txt
└── dataset/                    # 📊 PBF data storage
```

## 🎛️ Key Features

### 1. Vector Tiles (Real-time Rendering)
- **Pros**: Detailed, smooth zoom, interactive
- **Cons**: Slow with large datasets (network bottleneck)
- **Use Case**: Up to ~200k polygons
- **Usage**: Enable "OSM Buildings (Vector)" checkbox in web interface

### 2. Raster Tiles (PNG Images)
- **Pros**: Fast with massive data (100M+ polygons supported)
- **Cons**: Pixelated when zoomed, no interaction
- **Use Case**: 1M to 100M polygons
- **Usage**: Enable "OSM Buildings (Image)" checkbox in web interface

### 3. Pre-generated Tiles (Batch Processing)
Pre-generate PNG tiles from massive datasets for ultra-fast serving:

```bash
# Python high-performance version (recommended) - 30-50 concurrent
uv venv && source .venv/bin/activate
uv pip install aiohttp aiofiles asyncpg
python3 scripts/generate_tiles.py -z 5,18 -c 50

# Or use uv run (simpler)
uv run --with aiohttp --with aiofiles --with asyncpg scripts/generate_tiles.py -z 5,18 -c 50

# Bash version
./scripts/generate-tiles.sh -z 5,18 -p 20
```

## 📊 Performance & Storage Info

### Performance Comparison (Seoul Building Data)
| Method | Data Size | Response Speed | Quality | Interaction |
|--------|-----------|----------------|---------|-------------|
| Vector Tiles | ~200k | Medium | Best | ⭐⭐⭐ |
| Raster Tiles | ~100M | Fast | Good | ❌ |
| Pre-generated | Unlimited | Fastest | Good | ❌ |

### Storage Calculation (Zoom 16-21, Seoul Area)
```
Zoom 16:     6,440 tiles
Zoom 17:    25,437 tiles
Zoom 18:   100,740 tiles  
Zoom 19:   402,408 tiles
Zoom 20: 1,607,071 tiles
Zoom 21: 6,428,284 tiles

Total: 8,570,380 tiles = ~2.6GB
```

## 🛠️ Configuration Files

### docker-compose.yml Key Settings
```yaml
services:
  postgis:
    image: postgis/postgis:16-3.4
    environment:
      POSTGRES_DB: martin_db
      POSTGRES_USER: martin_user  
      POSTGRES_PASSWORD: martin_password
    volumes:
      - postgis_data:/var/lib/postgresql/data
      - ./init-db:/docker-entrypoint-initdb.d
      - ./dataset:/data

  martin:
    image: ghcr.io/maplibre/martin:latest
    depends_on:
      - postgis
    volumes:
      - ./martin-config.yaml:/config.yaml

  nginx:
    image: nginx:alpine
    ports:
      - "8080:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
      - ./web:/usr/share/nginx/html
```

### martin-config.yaml Optimized Settings
```yaml
postgres:
  connection_string: "postgresql://martin_user:martin_password@postgis:5432/martin_db"

cache:
  size: 2147483648  # 2GB

tables:
  osm_polygon:
    minzoom: 5
    maxzoom: 21
    buffer: 32
    extent: 2048

functions:
  raster_osm_polygons:
    minzoom: 5
    maxzoom: 21
    buffer: 32
    extent: 2048
```

## 🔧 Troubleshooting

### Common Issues

#### 1. Port Conflict (8080 already in use)
```bash
# Check port usage
lsof -i :8080

# Change port in docker-compose.yml
ports:
  - "9080:80"  # Change 8080 → 9080
```

#### 2. Database Connection Failed
```bash
# Check container status
docker-compose ps

# Check logs
docker-compose logs postgis
docker-compose logs martin

# Test database connection
docker-compose exec postgis psql -U martin_user -d martin_db -c "SELECT version();"
```

#### 3. Out of Memory
```bash
# Check container resource usage
docker stats

# Increase memory allocation in Docker Desktop (minimum 4GB recommended)
# Settings → Resources → Memory → Set 4GB or more
```

#### 4. Web Page Shows No Map
```bash
# Check Martin server response
curl http://localhost:3000/health

# Check Nginx status
curl http://localhost:8080

# Check network errors in browser developer tools
```

### Log Checking
```bash
# All service logs (real-time)
docker-compose logs -f

# Specific service logs
docker-compose logs -f martin
docker-compose logs -f postgis
docker-compose logs -f nginx

# Filter errors only
docker-compose logs | grep -i error
```

## 🚧 Development Mode

### Direct Database Access
```bash
# Connect to psql console
docker-compose exec postgis psql -U martin_user -d martin_db

# List tables
\dt

# Check data samples
SELECT name, building, ST_AsText(ST_Centroid(way)) FROM osm_polygon LIMIT 5;

# Table statistics
SELECT 
  COUNT(*) as total_rows,
  COUNT(CASE WHEN building IS NOT NULL THEN 1 END) as buildings
FROM osm_polygon;
```

### Restart After Configuration Changes
```bash
# After Martin configuration changes
docker-compose restart martin

# After Nginx configuration changes
docker-compose restart nginx

# Restart all services
docker-compose restart
```

### Development Commands
```bash
# Run in development mode (with logs)
docker-compose up

# Run in background
docker-compose up -d

# Rebuild specific service
docker-compose up -d --force-recreate martin

# Complete reset (including volumes)
docker-compose down -v
```

## 📚 References

### Official Documentation
- [Martin Documentation](https://martin.maplibre.org/)
- [PostGIS Manual](https://postgis.net/documentation/)
- [OpenLayers Examples](https://openlayers.org/en/latest/examples/)
- [OSM2PGSQL Manual](https://osm2pgsql.org/doc/)

### Performance Tuning
- [PostGIS Performance Tips](https://postgis.net/workshops/postgis-intro/performance.html)
- [Martin Configuration Reference](https://martin.maplibre.org/configuration.html)
- [Vector Tile Specification](https://github.com/mapbox/vector-tile-spec)

### Data Sources
- [Geofabrik Downloads](https://download.geofabrik.de/) - PBF files
- [OpenStreetMap Wiki](https://wiki.openstreetmap.org/) - Data schema

## ⚖️ License

This project follows the MIT License.

---

## 🎯 Next Steps

After successful project setup:

1. **Web Interface**: Access http://localhost:8080
2. **Vector/Raster Layer Comparison**: Toggle layers with checkboxes
3. **Large Data Testing**: Run `generate_tiles.py` script
4. **Performance Monitoring**: Check resource usage with `docker stats`

### 💡 Tips
- Performance improves after initial loading due to caching
- Notice raster tile performance difference at zoom levels 18+
- For massive datasets, combine pre-generation + CDN

**Happy Mapping!** 🗺️✨