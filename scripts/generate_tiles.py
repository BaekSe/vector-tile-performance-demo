#!/usr/bin/env python3
"""
대규모 폴리곤 PNG 타일 사전 생성 스크립트
1억개 폴리곤도 배치 처리로 미리 렌더링
"""

import os
import sys
import math
import time
import argparse
import asyncio
import aiohttp
import aiofiles
import asyncpg
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from typing import Tuple, List, Optional
import logging

class TileGenerator:
    def __init__(self, martin_url: str, output_dir: str, max_concurrent: int = 10, db_url: str = None):
        self.martin_url = martin_url.rstrip('/')
        self.output_dir = Path(output_dir)
        self.max_concurrent = max_concurrent
        self.db_url = db_url or "postgresql://martin_user:martin_password@localhost:5432/martin_db"
        self.session: Optional[aiohttp.ClientSession] = None
        self.stats = {
            'total': 0,
            'completed': 0, 
            'failed': 0,
            'skipped': 0,
            'start_time': 0
        }
        
        # 로깅 설정
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(self.output_dir / 'tile_generation.log'),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger(__name__)

    async def get_polygon_bounds(self) -> Tuple[float, float, float, float]:
        """데이터베이스에서 폴리곤이 있는 실제 경계 상자 계산"""
        self.logger.info("데이터베이스에서 폴리곤 경계 상자 계산 중...")
        
        try:
            conn = await asyncpg.connect(self.db_url)
            
            # 폴리곤 테이블의 전체 경계 상자 계산
            query = """
            SELECT 
                ST_XMin(extent) as min_lon,
                ST_YMin(extent) as min_lat, 
                ST_XMax(extent) as max_lon,
                ST_YMax(extent) as max_lat,
                COUNT(*) as polygon_count
            FROM (
                SELECT ST_Transform(ST_Extent(way), 4326) as extent
                FROM osm_polygon 
                WHERE building IS NOT NULL
                AND way IS NOT NULL
            ) subq;
            """
            
            result = await conn.fetchrow(query)
            await conn.close()
            
            if result and result['polygon_count'] > 0:
                bbox = (
                    float(result['min_lon']), 
                    float(result['min_lat']),
                    float(result['max_lon']), 
                    float(result['max_lat'])
                )
                
                self.logger.info(f"폴리곤 발견: {result['polygon_count']:,}개")
                self.logger.info(f"경계 상자: {bbox[0]:.4f},{bbox[1]:.4f},{bbox[2]:.4f},{bbox[3]:.4f}")
                self.logger.info(f"범위: 경도 {bbox[2]-bbox[0]:.4f}°, 위도 {bbox[3]-bbox[1]:.4f}°")
                
                return bbox
            else:
                raise ValueError("폴리곤 데이터를 찾을 수 없습니다")
                
        except Exception as e:
            self.logger.error(f"데이터베이스 조회 실패: {e}")
            self.logger.warning("기본 서울 영역으로 설정")
            return (126.7, 37.4, 127.2, 37.7)  # 기본값: 서울

    def deg2num(self, lat_deg: float, lon_deg: float, zoom: int) -> Tuple[int, int]:
        """위도/경도를 타일 번호로 변환"""
        lat_rad = math.radians(lat_deg)
        n = 2.0 ** zoom
        x = int((lon_deg + 180.0) / 360.0 * n)
        y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
        return (x, y)

    def get_tile_bounds(self, bbox: Tuple[float, float, float, float], zoom: int) -> Tuple[int, int, int, int]:
        """경계 상자에서 타일 범위 계산"""
        min_lon, min_lat, max_lon, max_lat = bbox
        x_min, y_max = self.deg2num(min_lat, min_lon, zoom)
        x_max, y_min = self.deg2num(max_lat, max_lon, zoom)
        return (x_min, y_min, x_max, y_max)

    def calculate_total_tiles(self, bbox: Tuple[float, float, float, float], 
                            min_zoom: int, max_zoom: int) -> int:
        """총 타일 수 계산"""
        total = 0
        self.logger.info("줌 레벨별 타일 수:")
        
        for zoom in range(min_zoom, max_zoom + 1):
            x_min, y_min, x_max, y_max = self.get_tile_bounds(bbox, zoom)
            tiles_in_zoom = (x_max - x_min + 1) * (y_max - y_min + 1)
            total += tiles_in_zoom
            self.logger.info(f"  줌 {zoom}: {tiles_in_zoom:,}개")
        
        self.logger.info(f"총 예상 타일 수: {total:,}개")
        return total

    async def download_tile(self, semaphore: asyncio.Semaphore, z: int, x: int, y: int) -> bool:
        """단일 타일 비동기 다운로드"""
        async with semaphore:
            tile_path = self.output_dir / str(z) / str(x) / f"{y}.png"
            
            # 이미 존재하면 건너뛰기
            if tile_path.exists():
                self.stats['skipped'] += 1
                return True
            
            # 디렉토리 생성
            tile_path.parent.mkdir(parents=True, exist_ok=True)
            
            url = f"{self.martin_url}/{z}/{x}/{y}"
            
            try:
                # 3회 재시도
                for attempt in range(3):
                    try:
                        async with self.session.get(url, timeout=30) as response:
                            if response.status == 200:
                                content = await response.read()
                                
                                # PNG 헤더 확인
                                if content.startswith(b'\x89PNG'):
                                    async with aiofiles.open(tile_path, 'wb') as f:
                                        await f.write(content)
                                    
                                    self.stats['completed'] += 1
                                    
                                    # 진행률 출력
                                    if self.stats['completed'] % 100 == 0:
                                        self._log_progress()
                                    
                                    return True
                                else:
                                    self.logger.warning(f"{z}/{x}/{y}: 잘못된 PNG 형식")
                            else:
                                self.logger.warning(f"{z}/{x}/{y}: HTTP {response.status}")
                        
                    except asyncio.TimeoutError:
                        self.logger.warning(f"{z}/{x}/{y}: 타임아웃 (시도 {attempt + 1}/3)")
                    except Exception as e:
                        self.logger.warning(f"{z}/{x}/{y}: {str(e)} (시도 {attempt + 1}/3)")
                    
                    if attempt < 2:  # 마지막 시도가 아니면 잠시 대기
                        await asyncio.sleep(1)
                
                # 모든 시도 실패
                self.stats['failed'] += 1
                self.logger.error(f"{z}/{x}/{y}: 최종 실패")
                return False
                
            except Exception as e:
                self.stats['failed'] += 1
                self.logger.error(f"{z}/{x}/{y}: 예외 발생 - {str(e)}")
                return False

    def _log_progress(self):
        """진행률 로깅"""
        elapsed = time.time() - self.stats['start_time']
        completed = self.stats['completed']
        total = self.stats['total']
        progress = (completed / total * 100) if total > 0 else 0
        
        if completed > 0:
            eta = elapsed * (total - completed) / completed
            rate = completed / elapsed
            self.logger.info(
                f"진행률: {progress:.1f}% "
                f"({completed:,}/{total:,}) "
                f"속도: {rate:.1f}/초 "
                f"ETA: {eta/60:.1f}분"
            )

    async def generate_zoom_level(self, zoom: int, bbox: Tuple[float, float, float, float]):
        """특정 줌 레벨의 모든 타일 생성"""
        x_min, y_min, x_max, y_max = self.get_tile_bounds(bbox, zoom)
        tiles_in_zoom = (x_max - x_min + 1) * (y_max - y_min + 1)
        
        self.logger.info(f"줌 레벨 {zoom} 처리 중...")
        self.logger.info(f"  타일 범위: X({x_min}-{x_max}), Y({y_min}-{y_max})")
        self.logger.info(f"  타일 수: {tiles_in_zoom:,}개")
        
        start_time = time.time()
        
        # 세마포어로 동시 요청 수 제한
        semaphore = asyncio.Semaphore(self.max_concurrent)
        
        # 모든 타일 작업 생성
        tasks = []
        for x in range(x_min, x_max + 1):
            for y in range(y_min, y_max + 1):
                task = self.download_tile(semaphore, zoom, x, y)
                tasks.append(task)
        
        # 모든 타일 다운로드 실행
        await asyncio.gather(*tasks, return_exceptions=True)
        
        elapsed = time.time() - start_time
        self.logger.info(f"줌 레벨 {zoom} 완료 ({elapsed:.1f}초)")

    async def generate_tiles(self, bbox: Tuple[float, float, float, float], 
                           min_zoom: int, max_zoom: int):
        """모든 줌 레벨의 타일 생성"""
        
        # 출력 디렉토리 생성
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        # 통계 초기화
        self.stats['total'] = self.calculate_total_tiles(bbox, min_zoom, max_zoom)
        self.stats['start_time'] = time.time()
        
        # HTTP 세션 생성
        timeout = aiohttp.ClientTimeout(total=60)
        connector = aiohttp.TCPConnector(limit=100, ttl_dns_cache=300)
        self.session = aiohttp.ClientSession(timeout=timeout, connector=connector)
        
        try:
            # 각 줌 레벨 처리
            for zoom in range(min_zoom, max_zoom + 1):
                await self.generate_zoom_level(zoom, bbox)
                
                # 중간 통계 출력
                self.logger.info(
                    f"중간 통계 - 완료: {self.stats['completed']:,}, "
                    f"실패: {self.stats['failed']:,}, "
                    f"건너뛰기: {self.stats['skipped']:,}"
                )
        
        finally:
            await self.session.close()
        
        # 최종 통계
        total_time = time.time() - self.stats['start_time']
        total_files = sum(1 for _ in self.output_dir.rglob("*.png"))
        
        self.logger.info("타일 생성 완료!")
        self.logger.info(f"총 소요 시간: {total_time/60:.1f}분")
        self.logger.info(f"저장 위치: {self.output_dir}")
        self.logger.info(f"생성된 파일: {total_files:,}개")
        self.logger.info(f"성공: {self.stats['completed']:,}")
        self.logger.info(f"실패: {self.stats['failed']:,}")
        self.logger.info(f"건너뛰기: {self.stats['skipped']:,}")

async def main():
    parser = argparse.ArgumentParser(description='대규모 폴리곤 PNG 타일 사전 생성')
    parser.add_argument('-u', '--url', default='http://localhost:8080/api/raster_osm_polygons',
                       help='Martin 래스터 함수 URL')
    parser.add_argument('-o', '--output', default='./tiles',
                       help='출력 디렉토리')
    parser.add_argument('-z', '--zoom', default='5,18',
                       help='줌 레벨 범위 (예: 5,18)')
    parser.add_argument('-b', '--bbox', default=None,
                       help='경계 상자 lon1,lat1,lon2,lat2 (기본값: DB에서 자동 계산)')
    parser.add_argument('-c', '--concurrent', type=int, default=10,
                       help='동시 다운로드 수')
    parser.add_argument('-d', '--db', default=None,
                       help='PostgreSQL 연결 URL (기본값: localhost martin_db)')
    
    args = parser.parse_args()
    
    # 파라미터 파싱
    min_zoom, max_zoom = map(int, args.zoom.split(','))
    
    print("PNG 타일 사전 생성 시작")
    print(f"줌 레벨: {min_zoom} ~ {max_zoom}")
    print(f"저장 경로: {args.output}")
    print(f"동시 처리: {args.concurrent}")
    print()
    
    # 타일 생성기 초기화
    generator = TileGenerator(args.url, args.output, args.concurrent, args.db)
    
    # 경계 상자 결정
    if args.bbox:
        bbox = tuple(map(float, args.bbox.split(',')))
        print(f"수동 설정 영역: {args.bbox}")
    else:
        print("데이터베이스에서 폴리곤 영역 자동 탐지...")
        bbox = await generator.get_polygon_bounds()
        print(f"자동 계산 영역: {bbox[0]:.4f},{bbox[1]:.4f},{bbox[2]:.4f},{bbox[3]:.4f}")
    
    print()
    
    # 타일 생성 실행
    await generator.generate_tiles(bbox, min_zoom, max_zoom)

if __name__ == '__main__':
    # Python 3.7+ 필요
    if sys.version_info < (3, 7):
        print("Python 3.7 이상이 필요합니다.")
        sys.exit(1)
    
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n사용자에 의해 중단됨")
    except Exception as e:
        print(f"오류 발생: {e}")
        sys.exit(1)