"""
app.py  –  Nyvra Safety API  v3.8  (TIME-AWARE SCORES)
=======================================================
Start:
    uvicorn app:app --host 0.0.0.0 --port 8000 --reload

Changes vs v3.7
───────────────
• _predict_danger() now accepts `hour` and applies a POST-MODEL time penalty
  so scores drop realistically at night even though the ML model was trained
  on random hours.
• Night   (10 PM – 5 AM) : 25–40 point penalty (scales with location risk)
• Evening (6 PM – 10 PM) : 10–20 point penalty
• Day     (5 AM – 6 PM)  : no penalty
• danger_level and danger_label are now re-derived from the final adjusted
  score so the label always matches what the user sees.
• _score_to_factors() gives richer, time-aware factor messages.
• All other logic (models, endpoints, OSRM, heatmap, AI) unchanged.
"""

import asyncio
import datetime
import logging
import math
import os
import pickle
import warnings
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Optional

import numpy as np
import pandas as pd
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from geopy.distance import geodesic
from pydantic import BaseModel

warnings.filterwarnings("ignore")
logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger("nyvra")

# ── Groq (optional) ───────────────────────────────────────────────────────
_groq_key = os.environ.get("GROQ_API_KEY")
try:
    from groq import Groq
    groq_client = Groq(api_key=_groq_key)
    log.info("Groq client ready")
except Exception as _e:
    groq_client = None
    log.warning("Groq unavailable: %s", _e)

# ── httpx (optional, for OSRM) ────────────────────────────────────────────
try:
    import httpx as _httpx
    _HTTPX_OK = True
except ImportError:
    _HTTPX_OK = False

# ── FastAPI app ────────────────────────────────────────────────────────────
app = FastAPI(title="Nyvra Safety API", version="3.8")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

MODELS_DIR    = os.path.join(os.path.dirname(__file__), "models")
DANGER_LABELS = {0: "Low", 1: "Medium", 2: "High"}

R_0P5 = 0.5 / 6371.0
R_1KM = 1.0 / 6371.0
R_2KM = 2.0 / 6371.0


# ══════════════════════════════════════════════════════════════════════════
#  MODEL LOADING  — graceful, never raises on optional models
# ══════════════════════════════════════════════════════════════════════════
import requests

HF_BASE = "https://huggingface.co/supriyachola/nyvra-models/resolve/main/models"

def _load(name: str):
    path = os.path.join(MODELS_DIR, f"{name}.pkl")
    if not os.path.exists(path):
        raise FileNotFoundError(f"'{path}' not found")
    with open(path, "rb") as f:
        return pickle.load(f)

def _try_load(name: str):
    try:
        return _load(name), True
    except Exception as e:
        log.warning("Could not load %s: %s", name, e)
        return None, False


print("=" * 55)
print("Loading Nyvra models …")

# Required
scaler      = _load("scaler")
kmeans      = _load("kmeans")
center_lat  = float(_load("center_lat"))
center_lon  = float(_load("center_lon"))
ball_tree   = _load("ball_tree")

# Column list — try X_columns first, fall back to feature_columns
X_columns, _xc_ok = _try_load("X_columns")
if not _xc_ok:
    X_columns, _fc_ok = _try_load("feature_columns")
    if not _fc_ok:
        raise RuntimeError("Neither X_columns.pkl nor feature_columns.pkl found.")

N_FEATURES = scaler.n_features_in_
log.info("Scaler expects %d features, X_columns has %d", N_FEATURES, len(X_columns))

# Prediction models — load all available
lgb_model, lgb_ok = _try_load("lgb_model")
xgb_model, xgb_ok = _try_load("xgb_model")
rf_model,  rf_ok  = _try_load("rf_model")
et_model,  et_ok  = _try_load("et_model")

_meta_raw, meta_ok = _try_load("meta_model")

if not any([lgb_ok, xgb_ok, rf_ok]):
    raise RuntimeError("No usable model found (lgb/xgb/rf all missing).")

_model_pool: List[tuple] = []
if lgb_ok:  _model_pool.append((lgb_model, True,  "LightGBM"))
if xgb_ok:  _model_pool.append((xgb_model, False, "XGBoost"))
if rf_ok:   _model_pool.append((rf_model,  False, "RandomForest"))
if et_ok:   _model_pool.append((et_model,  False, "ExtraTrees"))

ENSEMBLE_OK = len(_model_pool) >= 2

print(f"✅  Models ready")
print(f"   Pool          : {[m[2] for m in _model_pool]}")
print(f"   Ensemble      : {ENSEMBLE_OK}")
print(f"   Feature cols  : {N_FEATURES}")
print(f"   KMeans k      : {kmeans.n_clusters}")
print(f"   Center        : ({center_lat:.4f}, {center_lon:.4f})")
print("=" * 55)


# ══════════════════════════════════════════════════════════════════════════
#  SCHEMAS
# ══════════════════════════════════════════════════════════════════════════
class AreaRequest(BaseModel):
    latitude:   float
    longitude:  float
    hour:       Optional[int] = None
    month:      Optional[int] = None
    is_weekend: Optional[int] = None

class RouteRequest(BaseModel):
    origin_lat: float
    origin_lng: float
    dest_lat:   float
    dest_lng:   float
    time:       Optional[str] = "Now"

class AreaResponse(BaseModel):
    safety_score: int
    danger_level: str
    danger_label: int
    factors:      List[str]

class RouteResult(BaseModel):
    name:           str
    duration:       str
    distance:       str
    safety_score:   int
    factors:        List[str]
    is_recommended: bool

class RouteResponse(BaseModel):
    overall_score: int
    routes:        List[RouteResult]

class HeatmapPoint(BaseModel):
    lat:   float
    lng:   float
    risk:  str
    score: int

class HeatmapResponse(BaseModel):
    points:     List[HeatmapPoint]
    center_lat: float
    center_lng: float

class AiRequest(BaseModel):
    message: str

class AiResponse(BaseModel):
    reply: str


# ══════════════════════════════════════════════════════════════════════════
#  TIME PENALTY  — compensates for ML model being trained on random hours
# ══════════════════════════════════════════════════════════════════════════
def _time_penalty(hour: int, safe_p: float) -> int:
    """
    Returns a score penalty (0–40) based on time of day.

    The ML model was trained on randomly assigned hours, so it cannot
    distinguish day from night by itself. We apply a deterministic
    post-model penalty so scores reflect real-world night-time risk.

    Penalty also scales with how unsafe the location already is:
    a dangerous area gets hit harder at night than a safe one.
    risk_factor = 1.0 (very unsafe) → 0.5 (very safe)
    """
    risk_factor = 1.0 - (safe_p * 0.5)   # 0.5 – 1.0

    if (hour >= 22) or (hour <= 5):
        # Deep night: 10 PM – 5 AM
        base = 30
        extra = int(risk_factor * 20)     # up to +20 for risky areas
        return base + extra               # total: 30 – 50

    if (hour >= 18) and (hour < 22):
        # Evening: 6 PM – 10 PM
        base = 10
        extra = int(risk_factor * 10)     # up to +10 for risky areas
        return base + extra               # total: 10 – 20

    if (hour >= 5) and (hour < 7):
        # Early morning: 5 AM – 7 AM
        return 10

    # Daytime: 7 AM – 6 PM — no penalty
    return 0


def _score_to_label(score: int) -> tuple:
    """Re-derive danger label and level from the final adjusted score."""
    if score >= 70:
        return 0, "Low"
    elif score >= 45:
        return 1, "Medium"
    else:
        return 2, "High"


# ══════════════════════════════════════════════════════════════════════════
#  FEATURE ENGINEERING
# ══════════════════════════════════════════════════════════════════════════
def _build_feature_row(
    lat: float, lon: float,
    hour: int = 12, month: int = 6, is_weekend: int = 0,
) -> np.ndarray:
    dist_km      = geodesic((lat, lon), (center_lat, center_lon)).km
    dist_sq      = dist_km ** 2
    dist_log     = math.log1p(dist_km)
    lat_lon_prod = lat * lon

    coord_rad = np.radians([[lat, lon]])
    d_0p5 = int(ball_tree.query_radius(coord_rad, r=R_0P5, count_only=True)[0])
    d_1km = int(ball_tree.query_radius(coord_rad, r=R_1KM, count_only=True)[0])
    d_2km = int(ball_tree.query_radius(coord_rad, r=R_2KM, count_only=True)[0])

    log_d_0p5      = math.log1p(d_0p5)
    log_d_1        = math.log1p(d_1km)
    log_d_2        = math.log1p(d_2km)
    density_ratio  = d_1km / (d_0p5 + 1)
    density_growth = d_2km / (d_1km + 1)
    density_dist   = d_1km * dist_km
    density_sq     = float(d_1km ** 2)
    density_0p5_sq = float(d_0p5 ** 2)

    cluster_id  = int(kmeans.predict([[lat, lon]])[0])
    cluster_ctr = kmeans.cluster_centers_[cluster_id]
    dist_to_ctr = geodesic((lat, lon), (cluster_ctr[0], cluster_ctr[1])).km

    quarter   = (month - 1) // 3 + 1
    is_night  = int((hour >= 20) or (hour <= 5))
    hour_sin  = math.sin(2 * math.pi * hour  / 24)
    hour_cos  = math.cos(2 * math.pi * hour  / 24)
    month_sin = math.sin(2 * math.pi * month / 12)
    month_cos = math.cos(2 * math.pi * month / 12)

    row: dict = {
        "Latitude":                 lat,
        "Longitude":                lon,
        "dist_to_center_km":        dist_km,
        "dist_sq":                  dist_sq,
        "dist_log":                 dist_log,
        "lat_lon_product":          lat_lon_prod,
        "dist_to_cluster_ctr":      dist_to_ctr,
        "density_0p5km":            float(d_0p5),
        "density_1km":              float(d_1km),
        "density_2km":              float(d_2km),
        "log_density_0p5":          log_d_0p5,
        "log_density_1":            log_d_1,
        "log_density_2":            log_d_2,
        "density_ratio":            density_ratio,
        "density_growth":           density_growth,
        "density_dist_interaction": density_dist,
        "density_sq":               density_sq,
        "density_0p5_sq":           density_0p5_sq,
        "cluster_danger_rate":      0.0,
        "cluster_danger_high":      0.0,
        "cluster_danger_std":       0.0,
        "grid_danger_rate":         0.0,
        "grid_density":             float(d_1km),
        "grid_high_rate":           0.0,
        "neighbour_risk_mean":      0.0,
        "neighbour_risk_std":       0.0,
        "FIR_MONTH":                float(month),
        "FIR_QUARTER":              float(quarter),
        "FIR_IS_WEEKEND":           float(is_weekend),
        "is_night":                 float(is_night),
        "hour_sin":                 hour_sin,
        "hour_cos":                 hour_cos,
        "month_sin":                month_sin,
        "month_cos":                month_cos,
        "case_age_yrs":             0.0,
        f"cluster_{cluster_id}":    1.0,
    }

    row.setdefault("pseudo_crime_type", 0.0)
    row.setdefault("cluster_id", float(cluster_id))

    df = pd.DataFrame([row])
    for col in X_columns:
        if col not in df.columns:
            df[col] = 0.0
    df = df[X_columns].fillna(0.0)

    arr = df.to_numpy()
    if arr.shape[1] < N_FEATURES:
        arr = np.hstack([arr, np.zeros((1, N_FEATURES - arr.shape[1]))])
    elif arr.shape[1] > N_FEATURES:
        arr = arr[:, :N_FEATURES]

    return arr


# ══════════════════════════════════════════════════════════════════════════
#  SAFE PROBA CALL
# ══════════════════════════════════════════════════════════════════════════
def _safe_proba(model, X_scaled: np.ndarray, is_lgb: bool) -> Optional[np.ndarray]:
    try:
        name = type(model).__name__
        if hasattr(model, "predict") and "Booster" in name:
            p = model.predict(X_scaled)
            return p[0] if p.ndim == 2 else p
        if is_lgb:
            return model.predict_proba(X_scaled)[0]
        if "XGB" in name:
            return model.predict_proba(X_scaled)[0]
        if "LogisticRegression" in name:
            try:
                scores = model.decision_function(X_scaled)[0]
                e = np.exp(scores - scores.max())
                return e / e.sum()
            except Exception:
                return None
        return model.predict_proba(X_scaled)[0]
    except Exception as e:
        log.warning("Model %s predict failed: %s", type(model).__name__, e)
        return None


# ══════════════════════════════════════════════════════════════════════════
#  PREDICTION  — with time-aware post-model score adjustment
# ══════════════════════════════════════════════════════════════════════════
def _predict_danger(
    lat: float, lon: float,
    hour: int = 12, month: int = 6, is_weekend: int = 0,
) -> dict:
    X_raw    = _build_feature_row(lat, lon, hour, month, is_weekend)
    X_scaled = scaler.transform(X_raw)

    probas = []
    for model, is_lgb, mname in _model_pool:
        p = _safe_proba(model, X_scaled, is_lgb)
        if p is not None and len(p) == 3:
            probas.append(p)

    if not probas:
        log.error("All models failed for (%.4f, %.4f) — neutral fallback", lat, lon)
        proba = np.array([0.33, 0.34, 0.33])
    elif len(probas) == 1:
        proba = probas[0]
    else:
        proba = np.mean(probas, axis=0)

    safe_p = float(proba[0])
    high_p = float(proba[2])

    # ── Base score from ML probabilities ──────────────────────────────────
    base_score = max(0, min(100, int(safe_p * 60 + (1.0 - high_p) * 40)))

    # ── Time-aware penalty (compensates for hour-blind training data) ─────
    penalty = _time_penalty(hour, safe_p)
    score   = max(10, min(100, base_score - penalty))

    # ── Re-derive label from final adjusted score ─────────────────────────
    label, _ = _score_to_label(score)

    try:
        density_idx = list(X_columns).index("density_1km")
        density = int(X_raw[0, density_idx])
    except (ValueError, IndexError):
        density = 0

    return {
        "label":   label,
        "score":   score,
        "density": density,
        "hour":    hour,
    }


# ══════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════
def _score_to_factors(score: int, density: int, is_night: bool = False, hour: int = 12) -> List[str]:
    # Base safety factors
    if score >= 80:
        factors = ["Well-lit streets", "High foot traffic"]
    elif score >= 60:
        factors = ["Moderate foot traffic", "Some isolated roads"]
    elif score >= 40:
        factors = ["Limited lighting", "Below-average safety"]
    else:
        factors = ["High crime density", "Avoid if possible"]

    # Density factors
    if density > 20:
        factors.append(f"High incident density (~{density} nearby)")
    elif density > 5:
        factors.append(f"Moderate incidents (~{density} nearby)")
    else:
        factors.append("Low historical incidents")

    # Time-aware factors
    if (hour >= 22) or (hour <= 5):
        if score < 40:
            factors.append("🌙 High risk — avoid travel at this hour")
        elif score < 60:
            factors.append("🌙 Use caution — late night travel risky")
        else:
            factors.append("🌙 Relatively safer but stay alert at night")
    elif (hour >= 18) and (hour < 22):
        if score < 55:
            factors.append("🌆 Evening caution advised")
        else:
            factors.append("🌆 Moderate evening activity — stay aware")
    elif (hour >= 5) and (hour < 7):
        factors.append("🌅 Early morning — limited activity in area")

    return factors


def _now_params():
    n = datetime.datetime.now()
    return n.hour, n.month, int(n.weekday() >= 5)


def _parse_time(t: str) -> int:
    t = (t or "Now").lower().strip()
    if t in ("now", ""):      return datetime.datetime.now().hour
    if "night" in t:          return 22
    if "morning" in t:        return 8
    if "afternoon" in t:      return 14
    if "evening" in t:        return 18
    if "15 min" in t:         return datetime.datetime.now().hour
    if "30 min" in t:         return datetime.datetime.now().hour
    if "1 hour" in t:         return (datetime.datetime.now().hour + 1) % 24
    return datetime.datetime.now().hour


def _osrm_leg(o_lat, o_lng, d_lat, d_lng) -> dict:
    if _HTTPX_OK:
        try:
            r = _httpx.get(
                f"http://router.project-osrm.org/route/v1/driving/"
                f"{o_lng},{o_lat};{d_lng},{d_lat}?overview=false",
                timeout=3.0,
            )
            if r.status_code == 200:
                leg = r.json()["routes"][0]["legs"][0]
                return {
                    "dist_km": round(leg["distance"] / 1000, 1),
                    "mins":    max(1, round(leg["duration"] / 60)),
                }
        except Exception:
            pass
    straight = geodesic((o_lat, o_lng), (d_lat, d_lng)).km
    return {
        "dist_km": round(straight * 1.3, 1),
        "mins":    max(5, round(straight * 1.3 / 28 * 60)),
    }


def _build_routes(o_lat, o_lng, d_lat, d_lng, hour, month, is_weekend) -> RouteResponse:
    night = bool((hour >= 20) or (hour <= 5))

    m1_lat = (o_lat + d_lat) / 2 + 0.008
    m1_lng = (o_lng + d_lng) / 2 + 0.008
    m2_lat = (o_lat + d_lat) / 2 - 0.006
    m2_lng = (o_lng + d_lng) / 2 - 0.006

    with ThreadPoolExecutor(max_workers=8) as ex:
        f_main = ex.submit(_osrm_leg, o_lat,  o_lng,  d_lat,  d_lng)
        f_a1   = ex.submit(_osrm_leg, o_lat,  o_lng,  m1_lat, m1_lng)
        f_b1   = ex.submit(_osrm_leg, m1_lat, m1_lng, d_lat,  d_lng)
        f_a2   = ex.submit(_osrm_leg, o_lat,  o_lng,  m2_lat, m2_lng)
        f_b2   = ex.submit(_osrm_leg, m2_lat, m2_lng, d_lat,  d_lng)
        f_orig = ex.submit(_predict_danger, o_lat, o_lng, hour, month, is_weekend)
        f_dest = ex.submit(_predict_danger, d_lat, d_lng, hour, month, is_weekend)
        f_mid  = ex.submit(_predict_danger, (o_lat+d_lat)/2, (o_lng+d_lng)/2, hour, month, is_weekend)
        f_mid1 = ex.submit(_predict_danger, m1_lat, m1_lng, hour, month, is_weekend)
        f_mid2 = ex.submit(_predict_danger, m2_lat, m2_lng, hour, month, is_weekend)

        main   = f_main.result()
        a1, b1 = f_a1.result(), f_b1.result()
        a2, b2 = f_a2.result(), f_b2.result()
        orig_r = f_orig.result()
        dest_r = f_dest.result()
        mid_r  = f_mid.result()
        mid1_r = f_mid1.result()
        mid2_r = f_mid2.result()

    def ws(m: dict) -> int:
        return int(orig_r["score"] * 0.2 + m["score"] * 0.5 + dest_r["score"] * 0.3)

    routes_raw = [
        {
            "name":           "Main Route",
            "duration":       f"{main['mins']} min",
            "distance":       f"{main['dist_km']} km",
            "safety_score":   ws(mid_r),
            "factors":        _score_to_factors(ws(mid_r),  mid_r["density"],  night, hour),
            "is_recommended": False,
        },
        {
            "name":           "Alternate Route 1",
            "duration":       f"{a1['mins'] + b1['mins']} min",
            "distance":       f"{round(a1['dist_km'] + b1['dist_km'], 1)} km",
            "safety_score":   ws(mid1_r),
            "factors":        _score_to_factors(ws(mid1_r), mid1_r["density"], night, hour),
            "is_recommended": False,
        },
        {
            "name":           "Alternate Route 2",
            "duration":       f"{a2['mins'] + b2['mins']} min",
            "distance":       f"{round(a2['dist_km'] + b2['dist_km'], 1)} km",
            "safety_score":   ws(mid2_r),
            "factors":        _score_to_factors(ws(mid2_r), mid2_r["density"], night, hour),
            "is_recommended": False,
        },
    ]

    routes_raw.sort(key=lambda r: r["safety_score"], reverse=True)
    routes_raw[0]["is_recommended"] = True
    overall = int(sum(r["safety_score"] for r in routes_raw) / 3)

    return RouteResponse(
        overall_score=overall,
        routes=[RouteResult(**r) for r in routes_raw],
    )


# ══════════════════════════════════════════════════════════════════════════
#  ENDPOINTS
# ══════════════════════════════════════════════════════════════════════════

@app.get("/health")
def health():
    return {
        "status":     "ok",
        "version":    "3.8",
        "models":     [m[2] for m in _model_pool],
        "ensemble":   ENSEMBLE_OK,
        "n_features": N_FEATURES,
        "n_clusters": kmeans.n_clusters,
    }


# ── /predict_area  GET ────────────────────────────────────────────────────
@app.get("/predict_area", response_model=AreaResponse)
def predict_area_get(latitude: float, longitude: float):
    try:
        hour, month, iw = _now_params()
        r               = _predict_danger(latitude, longitude, hour, month, iw)
        label, level    = _score_to_label(r["score"])
        return AreaResponse(
            safety_score=r["score"],
            danger_level=level,
            danger_label=label,
            factors=_score_to_factors(r["score"], r["density"], (hour >= 20 or hour <= 5), hour),
        )
    except Exception as e:
        log.exception("predict_area_get failed")
        raise HTTPException(status_code=500, detail=str(e))


# ── /predict_area  POST ───────────────────────────────────────────────────
@app.post("/predict_area", response_model=AreaResponse)
def predict_area_post(req: AreaRequest):
    try:
        h, mo, iw  = _now_params()
        hour       = req.hour       if req.hour       is not None else h
        month      = req.month      if req.month      is not None else mo
        is_weekend = req.is_weekend if req.is_weekend is not None else iw
        r          = _predict_danger(req.latitude, req.longitude, hour, month, is_weekend)
        label, level = _score_to_label(r["score"])
        return AreaResponse(
            safety_score=r["score"],
            danger_level=level,
            danger_label=label,
            factors=_score_to_factors(r["score"], r["density"], (hour >= 20 or hour <= 5), hour),
        )
    except Exception as e:
        log.exception("predict_area_post failed")
        raise HTTPException(status_code=500, detail=str(e))


# ── /predict_area_full  POST (alias) ──────────────────────────────────────
@app.post("/predict_area_full", response_model=AreaResponse)
def predict_area_full(req: AreaRequest):
    return predict_area_post(req)


# ── /analyze_route  GET ───────────────────────────────────────────────────
@app.get("/analyze_route", response_model=RouteResponse)
def analyze_route_get(
    origin_lat: float, origin_lng: float,
    dest_lat:   float, dest_lng:   float,
    time: str = "Now",
):
    try:
        hour = _parse_time(time)
        _, month, iw = _now_params()
        return _build_routes(origin_lat, origin_lng, dest_lat, dest_lng,
                             hour, month, iw)
    except Exception as e:
        log.exception("analyze_route_get failed")
        raise HTTPException(status_code=500, detail=str(e))


# ── /analyze_route  POST ──────────────────────────────────────────────────
@app.post("/analyze_route", response_model=RouteResponse)
def analyze_route_post(req: RouteRequest):
    try:
        hour = _parse_time(req.time)
        _, month, iw = _now_params()
        return _build_routes(req.origin_lat, req.origin_lng,
                             req.dest_lat,   req.dest_lng,
                             hour, month, iw)
    except Exception as e:
        log.exception("analyze_route_post failed")
        raise HTTPException(status_code=500, detail=str(e))


# ── /heatmap_data  GET ────────────────────────────────────────────────────
@app.get("/heatmap_data", response_model=HeatmapResponse)
def heatmap_data(
    latitude:  float = 12.9716,
    longitude: float = 77.5946,
    radius_km: float = 2.0,
    step_km:   float = 0.3,
):
    try:
        hour, month, iw = _now_params()

        lat_step = step_km / 111.0
        lng_step = step_km / (111.0 * max(abs(math.cos(math.radians(latitude))), 0.01))

        lat_range = np.arange(latitude  - radius_km / 111.0,
                              latitude  + radius_km / 111.0, lat_step)
        lng_range = np.arange(longitude - radius_km / 111.0,
                              longitude + radius_km / 111.0, lng_step)

        MAX_PTS = 144
        if len(lat_range) * len(lng_range) > MAX_PTS:
            s = max(1, int(math.ceil(math.sqrt(
                len(lat_range) * len(lng_range) / MAX_PTS))))
            lat_range = lat_range[::s]
            lng_range = lng_range[::s]

        grid = [(float(la), float(lo)) for la in lat_range for lo in lng_range]
        log.info("Heatmap grid: %d points", len(grid))

        results_map: dict = {}
        with ThreadPoolExecutor(max_workers=16) as ex:
            futures = {
                ex.submit(_predict_danger, la, lo, hour, month, iw): (la, lo)
                for la, lo in grid
            }
            for fut in as_completed(futures):
                coord = futures[fut]
                try:
                    results_map[coord] = fut.result()
                except Exception as exc:
                    log.warning("Heatmap point %s skipped: %s", coord, exc)

        points = [
            HeatmapPoint(
                lat=round(la, 5), lng=round(lo, 5),
                risk=DANGER_LABELS[results_map[(la, lo)]["label"]],
                score=results_map[(la, lo)]["score"],
            )
            for la, lo in grid if (la, lo) in results_map
        ]

        if not points:
            raise HTTPException(status_code=500,
                                detail="No valid predictions returned.")

        return HeatmapResponse(points=points,
                               center_lat=latitude, center_lng=longitude)

    except HTTPException:
        raise
    except Exception as e:
        log.exception("heatmap_data failed")
        raise HTTPException(status_code=500, detail=str(e))


# ── /ai  POST ─────────────────────────────────────────────────────────────
@app.post("/ai", response_model=AiResponse)
async def ai_chat(body: AiRequest):
    try:
        msg   = body.message.strip()
        lower = msg.lower()

        if not msg:
            return AiResponse(reply="Please enter a message.")

        FAST = [
            ({"danger", "emergency", "attack", "unsafe", "threat", "help"},
             "⚠️ Stay calm. Call 112 immediately and move to a safe, crowded place."),
            ({"police"},
             "🚔 Call 112 for police assistance. Use the SOS button in the app for instant alerts."),
            ({"sos", "panic", "alert"},
             "🆘 Press the SOS button in the app to instantly alert your emergency contacts."),
            ({"hospital", "ambulance", "injured", "hurt", "accident", "medical"},
             "🏥 Call 108 for an ambulance. Tap 'Nearby Help' for the nearest hospital."),
            ({"route", "safe route", "path", "navigate", "direction"},
             "🗺️ Tap 'Plan Safe Route' on the home screen to get ML-rated safe routes."),
            ({"heatmap", "crime map", "danger zone", "safe area"},
             "🗺️ Check the Safety Heatmap on the home screen for real-time crime density."),
            ({"safe", "area", "location", "nearby"},
             "📍 I'm analysing your area using crime data. Use the heatmap for a visual overview."),
        ]
        for kws, reply in FAST:
            if any(k in lower for k in kws):
                return AiResponse(reply=reply)

        if groq_client is None:
            return AiResponse(
                reply="I'm your Nyvra safety assistant. For emergencies, call 112. "
                      "Use SOS in the app to alert your contacts instantly."
            )

        loop = asyncio.get_running_loop()
        resp = await loop.run_in_executor(
            None,
            lambda: groq_client.chat.completions.create(
                model="llama-3.1-8b-instant",
                max_tokens=120,
                temperature=0.4,
                messages=[
                    {"role": "system", "content": (
                        "You are Nyvra, a concise women's safety assistant for India. "
                        "Reply in 2-3 short sentences. Be calm, practical, empathetic. "
                        "For emergencies always say: call 112."
                    )},
                    {"role": "user", "content": msg},
                ],
            )
        )
        return AiResponse(reply=resp.choices[0].message.content.strip())

    except Exception as e:
        log.exception("ai_chat failed")
        return AiResponse(
            reply="I'm here to help with your safety. For emergencies, call 112 immediately."
        )


# ── Dev entry ──────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, reload=False)
