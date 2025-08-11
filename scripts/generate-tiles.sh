#!/bin/bash

# 사전 PNG 타일 생성 스크립트
# 대규모 폴리곤 데이터를 모든 줌 레벨에서 미리 렌더링

set -e  # 오류 시 중단

# 설정
MARTIN_URL="http://localhost:8080/api/raster_osm_polygons"
TILES_DIR="./tiles"
MIN_ZOOM=5
MAX_ZOOM=18
BBOX=""  # 기본값: 데이터베이스에서 자동 계산
MAX_PARALLEL=4                 # 병렬 처리 수
LOG_DIR="./logs"

# 디렉토리 생성
mkdir -p "$TILES_DIR"
mkdir -p "$LOG_DIR"

echo "PNG 타일 사전 생성 시작"
echo "줌 레벨: $MIN_ZOOM ~ $MAX_ZOOM"
echo "영역: $BBOX"
echo "저장 경로: $TILES_DIR"
echo "병렬 처리: $MAX_PARALLEL"
echo ""

# 데이터베이스에서 폴리곤 경계 상자 자동 계산
get_polygon_bounds() {
    local db_result=$(docker-compose exec -T postgis psql -U martin_user -d martin_db -t -c "
        SELECT 
            ST_XMin(extent) || ',' || ST_YMin(extent) || ',' || 
            ST_XMax(extent) || ',' || ST_YMax(extent) as bbox,
            COUNT(*) as count
        FROM (
            SELECT ST_Transform(ST_Extent(way), 4326) as extent
            FROM osm_polygon 
            WHERE building IS NOT NULL AND way IS NOT NULL
        ) subq;" 2>/dev/null | head -n1)
    
    if [[ -n "$db_result" && "$db_result" != *"null"* ]]; then
        local bbox_part=$(echo "$db_result" | cut -d'|' -f1 | tr -d ' ')
        local count_part=$(echo "$db_result" | cut -d'|' -f2 | tr -d ' ')
        
        # 진단 정보를 stderr로 출력 (반환값에 포함되지 않음)
        echo "데이터베이스에서 폴리곤 영역 자동 탐지..." >&2
        echo "폴리곤 발견: ${count_part}개" >&2
        echo "자동 계산 영역: $bbox_part" >&2
        
        # 실제 좌표만 stdout으로 반환
        echo "$bbox_part"
    else
        echo "데이터베이스 조회 실패, 기본 서울 영역 사용" >&2
        echo "126.7,37.4,127.2,37.7"
    fi
}

# 총 타일 수 계산 함수
calculate_total_tiles() {
    local min_z=$1
    local max_z=$2
    local bbox=$3
    
    # bbox가 비어있거나 잘못된 경우 처리
    if [[ -z "$bbox" || "$bbox" == *"데이터베이스"* ]]; then
        echo "경계 상자 정보가 없습니다. 기본값으로 계산을 건너뜁니다."
        return
    fi
    
    IFS=',' read -r min_lon min_lat max_lon max_lat <<< "$bbox"
    
    # 숫자 값 검증
    if ! [[ "$min_lon" =~ ^-?[0-9]+\.?[0-9]*$ ]] || ! [[ "$max_lon" =~ ^-?[0-9]+\.?[0-9]*$ ]] || 
       ! [[ "$min_lat" =~ ^-?[0-9]+\.?[0-9]*$ ]] || ! [[ "$max_lat" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        echo "잘못된 좌표 형식입니다: $bbox"
        return
    fi
    
    local total=0
    for z in $(seq $min_z $max_z); do
        # 경계 상자를 타일 좌표로 변환
        local x_min=$(python3 -c "import math; print(int((($min_lon + 180.0) / 360.0) * (1 << $z)))")
        local x_max=$(python3 -c "import math; print(int((($max_lon + 180.0) / 360.0) * (1 << $z)))")
        local y_min=$(python3 -c "import math; lat_rad = math.radians($max_lat); print(int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (1 << $z)))")
        local y_max=$(python3 -c "import math; lat_rad = math.radians($min_lat); print(int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (1 << $z)))")
        
        local tiles_in_zoom=$(( (x_max - x_min + 1) * (y_max - y_min + 1) ))
        total=$((total + tiles_in_zoom))
        
        echo "  줌 $z: ${tiles_in_zoom}개 타일"
    done
    
    echo "총 예상 타일 수: $total"
}

# 단일 타일 다운로드 함수
download_tile() {
    local z=$1
    local x=$2  
    local y=$3
    
    local tile_dir="$TILES_DIR/$z/$x"
    local tile_path="$tile_dir/$y.png"
    local url="$MARTIN_URL/$z/$x/$y"
    
    # 이미 존재하면 건너뛰기
    if [[ -f "$tile_path" ]]; then
        return 0
    fi
    
    # 디렉토리 생성
    mkdir -p "$tile_dir"
    
    # 타일 다운로드 (3회 재시도)
    for attempt in {1..3}; do
        if curl -s -f "$url" -o "$tile_path"; then
            # PNG 파일 유효성 검사
            if file "$tile_path" | grep -q "PNG"; then
                echo "$z/$x/$y OK"
                return 0
            else
                echo "$z/$x/$y 잘못된 PNG, 재시도 $attempt/3"
                rm -f "$tile_path"
            fi
        else
            echo "$z/$x/$y 다운로드 실패, 재시도 $attempt/3"
        fi
        sleep 1
    done
    
    echo "$z/$x/$y 최종 실패"
    return 1
}

# 줌 레벨별 타일 생성
generate_zoom_level() {
    local z=$1
    local bbox=$2
    
    echo "줌 레벨 $z 처리 중..."
    
    # 경계 상자를 타일 좌표로 변환
    IFS=',' read -r min_lon min_lat max_lon max_lat <<< "$bbox"
    
    local x_min=$(python3 -c "import math; print(int((($min_lon + 180.0) / 360.0) * (1 << $z)))")
    local x_max=$(python3 -c "import math; print(int((($max_lon + 180.0) / 360.0) * (1 << $z)))")
    local y_min=$(python3 -c "import math; lat_rad = math.radians($max_lat); print(int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (1 << $z)))")
    local y_max=$(python3 -c "import math; lat_rad = math.radians($min_lat); print(int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (1 << $z)))")
    
    local total_tiles=$(( (x_max - x_min + 1) * (y_max - y_min + 1) ))
    local completed=0
    local start_time=$(date +%s)
    
    echo "  타일 범위: X($x_min-$x_max), Y($y_min-$y_max)"
    echo "  총 타일 수: $total_tiles"
    
    # 병렬 처리로 타일 다운로드
    for x in $(seq $x_min $x_max); do
        for y in $(seq $y_min $y_max); do
            # 백그라운드에서 실행
            (
                download_tile $z $x $y
            ) &
            
            # 병렬 처리 수 제한
            while (( $(jobs -r | wc -l) >= MAX_PARALLEL )); do
                sleep 0.1
            done
            
            completed=$((completed + 1))
            
            # 진행률 출력 (100타일마다)
            if (( completed % 100 == 0 )); then
                local elapsed=$(($(date +%s) - start_time))
                local progress=$((completed * 100 / total_tiles))
                local eta=$(( elapsed * (total_tiles - completed) / completed ))
                echo "  진행률: ${progress}% (${completed}/${total_tiles}) ETA: ${eta}초"
            fi
        done
    done
    
    # 모든 백그라운드 작업 완료 대기
    wait
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo "줌 레벨 $z 완료 (${duration}초, ${total_tiles}개 타일)"
}

# 메인 실행
main() {
    local start_time=$(date +%s)
    
    # 경계 상자 결정
    if [[ -z "$BBOX" ]]; then
        BBOX=$(get_polygon_bounds)
        echo ""
    else
        echo "수동 설정 영역: $BBOX"
        echo ""
    fi
    
    # 총 타일 수 계산
    calculate_total_tiles $MIN_ZOOM $MAX_ZOOM "$BBOX"
    echo ""
    
    # 각 줌 레벨별로 처리
    for z in $(seq $MIN_ZOOM $MAX_ZOOM); do
        generate_zoom_level $z "$BBOX" 2>&1 | tee "$LOG_DIR/zoom_$z.log"
        echo ""
    done
    
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    echo "전체 타일 생성 완료!"
    echo "총 소요 시간: ${total_duration}초"
    echo "타일 저장 위치: $TILES_DIR"
    
    # 통계 정보
    local total_files=$(find "$TILES_DIR" -name "*.png" | wc -l)
    local total_size=$(du -sh "$TILES_DIR" | cut -f1)
    echo "생성된 타일 수: $total_files"
    echo "총 크기: $total_size"
}

# 사용법 출력
usage() {
    echo "사용법: $0 [옵션]"
    echo "옵션:"
    echo "  -z MIN_ZOOM,MAX_ZOOM    줌 레벨 범위 (기본: $MIN_ZOOM,$MAX_ZOOM)"
    echo "  -b BBOX                 경계 상자 lon1,lat1,lon2,lat2 (기본: DB에서 자동 계산)"
    echo "  -p PARALLEL             병렬 처리 수 (기본: $MAX_PARALLEL)"
    echo "  -d TILES_DIR            저장 디렉토리 (기본: $TILES_DIR)"
    echo "  -u MARTIN_URL           Martin URL (기본: $MARTIN_URL)"
    echo "  -h                      도움말"
    echo ""
    echo "예시:"
    echo "  $0 -z 10,15 -b \"126.9,37.5,127.1,37.6\" -p 8"
}

# 옵션 파싱
while getopts "z:b:p:d:u:h" opt; do
    case $opt in
        z) IFS=',' read -r MIN_ZOOM MAX_ZOOM <<< "$OPTARG" ;;
        b) BBOX="$OPTARG" ;;
        p) MAX_PARALLEL="$OPTARG" ;;
        d) TILES_DIR="$OPTARG" ;;
        u) MARTIN_URL="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) echo "잘못된 옵션: -$OPTARG" >&2; usage; exit 1 ;;
    esac
done

# 실행
main