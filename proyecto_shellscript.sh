#!/bin/bash

# ============================================================
# Proyecto: Monitorización de precios de carburantes
# Shell en entornos Linux - UPV
# ============================================================
# Ejecutar manualmente:
#   ./script_analisis_json.sh
#
# Para probar con un JSON local sin descargar de Internet:
#   JSON_PRUEBA=/ruta/descarga.json ./script_analisis_json.sh
#
# Cron propuesto (02:00 todos los días):
#   0 2 * * * /ruta/completa/proyecto_gasolineras_shell/script_analisis_json.sh >> /ruta/completa/proyecto_gasolineras_shell/log.txt 2>&1
# ============================================================

set -u

CARPETA_BASE="$(cd "$(dirname "$0")" && pwd)"
CARPETA_DATASETS="$CARPETA_BASE/datasets"
CARPETA_INFORMES="$CARPETA_BASE/informes"
LOG="$CARPETA_BASE/log.txt"

URL_API="https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/"
DIAS_RETENCION=7

FECHA_HORA=$(date '+%Y-%m-%d %H:%M:%S')
MARCA_TIEMPO=$(date '+%Y%m%d_%H%M%S')
FECHA_DIA=$(date '+%Y-%m-%d')

ARCHIVO_SALIDA="$CARPETA_DATASETS/precios_gasolineras_${MARCA_TIEMPO}.json"
INFORME_TXT="$CARPETA_INFORMES/informe_${MARCA_TIEMPO}.txt"
INFORME_HTML="$CARPETA_INFORMES/informe_${MARCA_TIEMPO}.html"

log() {
    echo "[$FECHA_HORA] $1" | tee -a "$LOG"
}

error() {
    echo "[$FECHA_HORA] ERROR: $1" | tee -a "$LOG" >&2
}

mkdir -p "$CARPETA_DATASETS" "$CARPETA_INFORMES"
touch "$LOG"

log "------------------------------------------------------------"
log "Inicio de ejecución."

# ------------------------------------------------------------
# 1. Comprobaciones básicas
# ------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
    error "No se encontró curl."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    error "No se encontró jq. Instálalo con: sudo apt install jq"
    exit 1
fi

# ------------------------------------------------------------
# 2. DESCARGA / CARGA DEL DATASET
# ------------------------------------------------------------
if [ -n "${JSON_PRUEBA:-}" ]; then
    log "Modo de prueba: usando archivo local $JSON_PRUEBA"
    if [ ! -f "$JSON_PRUEBA" ]; then
        error "El archivo de prueba no existe: $JSON_PRUEBA"
        exit 1
    fi
    cp "$JSON_PRUEBA" "$ARCHIVO_SALIDA"
else
    log "Descargando datos desde la API..."
    if ! curl -fsS --retry 2 --connect-timeout 20 --max-time 120 "$URL_API" -o "$ARCHIVO_SALIDA"; then
        error "Falló la descarga desde la API."
        rm -f "$ARCHIVO_SALIDA"
        exit 1
    fi
fi

if [ ! -s "$ARCHIVO_SALIDA" ]; then
    error "El archivo descargado está vacío."
    rm -f "$ARCHIVO_SALIDA"
    exit 1
fi

# ------------------------------------------------------------
# 3. VALIDACIÓN DE ESTRUCTURA
# ------------------------------------------------------------
if ! jq empty "$ARCHIVO_SALIDA" >/dev/null 2>&1; then
    error "El archivo no contiene un JSON válido."
    exit 1
fi

if ! jq -e '(.ListaEESSPrecio | type) == "array"' "$ARCHIVO_SALIDA" >/dev/null 2>&1; then
    error "La estructura del JSON no contiene ListaEESSPrecio como array."
    exit 1
fi

TOTAL_REGISTROS=$(jq '[.ListaEESSPrecio[] | select(type == "object")] | length' "$ARCHIVO_SALIDA")

if ! [[ "$TOTAL_REGISTROS" =~ ^[0-9]+$ ]]; then
    error "No se pudo obtener correctamente el total de registros."
    exit 1
fi

if [ "$TOTAL_REGISTROS" -eq 0 ]; then
    error "El dataset no contiene registros."
    exit 1
fi

log "Descarga/lectura correcta. Registros de estaciones encontrados: $TOTAL_REGISTROS"

# ------------------------------------------------------------
# 4. FUNCIONES DE PROCESAMIENTO
# ------------------------------------------------------------

# Devuelve mínimo, máximo y promedio para un campo de precio.
estadisticas_precio() {
    local campo="$1"
    local provincia="${2:-}"

    jq -r --arg campo "$campo" --arg provincia "$provincia" '
      [.ListaEESSPrecio[]
       | select($provincia == "" or .Provincia == $provincia)
       | .[$campo]
       | select(type == "string" and . != "")
       | gsub(","; ".")
       | tonumber
       | select(. > 0)]
      | if length == 0 then
          "N/A|N/A|N/A"
        else
          [min, max, (((add / length) * 1000 | round) / 1000)] | @tsv
        end
    ' "$ARCHIVO_SALIDA" | tr '\t' '|'
}

cantidad_precio_valido() {
    local campo="$1"

    jq -r --arg campo "$campo" '
      [.ListaEESSPrecio[]
       | .[$campo]
       | select(type == "string" and . != "")
       | gsub(","; ".")
       | tonumber
       | select(. > 0)]
      | length
    ' "$ARCHIVO_SALIDA"
}

# Obtiene precio, gasolinera, provincia, municipio y direccion
# para el minimo o maximo de un combustible.
estacion_extrema() {
    local campo="$1"
    local tipo="$2"
    local provincia="${3:-}"

    jq -r --arg campo "$campo" --arg tipo "$tipo" --arg provincia "$provincia" '
      [ .ListaEESSPrecio[]
        | select($provincia == "" or .Provincia == $provincia)
        | . as $e
        | $e[$campo] as $precio
        | select($precio != null and $precio != "")
        | ($precio | gsub(","; ".") | tonumber) as $precio_num
        | select($precio_num > 0)
        | {
            precio: $precio_num,
            rotulo: ($e["Rótulo"] // "Sin rótulo"),
            provincia: ($e.Provincia // "Sin provincia"),
            municipio: ($e.Municipio // "Sin municipio"),
            direccion: ($e["Dirección"] // "Sin dirección")
          }
      ]
      | if length == 0 then
          "N/A|N/A|N/A|N/A|N/A"
        elif $tipo == "min" then
          min_by(.precio) | [.precio, .rotulo, .provincia, .municipio, .direccion] | @tsv
        else
          max_by(.precio) | [.precio, .rotulo, .provincia, .municipio, .direccion] | @tsv
        end
    ' "$ARCHIVO_SALIDA" | tr '\t' '|'
}

# Extrae las 5 estaciones más baratas de Valencia para el combustible indicado.
top5_valencia() {
    local campo="$1"

    jq -r --arg campo "$campo" '
      [.ListaEESSPrecio[]
       | select(.Provincia == "VALENCIA / VALÈNCIA")
       | .[$campo] as $precio
       | select($precio != null and $precio != "")
       | ($precio | gsub(","; ".") | tonumber) as $precio_num
       | select($precio_num > 0)
       | {
           precio: $precio_num,
           rotulo: (.["Rótulo"] // "Sin rótulo"),
           municipio: (.Municipio // "Sin municipio"),
           direccion: (.["Dirección"] // "Sin dirección")
         }
      ]
      | sort_by(.precio)
      | .[:5]
      | .[]
      | [.precio, .rotulo, .municipio, .direccion]
      | @tsv
    ' "$ARCHIVO_SALIDA"
}

log "Procesando estadísticas con jq..."

G95="$(estadisticas_precio 'Precio Gasolina 95 E5')"
G95_VALENCIA="$(estadisticas_precio 'Precio Gasolina 95 E5' 'VALENCIA / VALÈNCIA')"
G98="$(estadisticas_precio 'Precio Gasolina 98 E5')"
G98_VALENCIA="$(estadisticas_precio 'Precio Gasolina 98 E5' 'VALENCIA / VALÈNCIA')"
GASOLEO="$(estadisticas_precio 'Precio Gasoleo A')"
GASOLEO_VALENCIA="$(estadisticas_precio 'Precio Gasoleo A' 'VALENCIA / VALÈNCIA')"

G95_MIN=$(echo "$G95" | cut -d'|' -f1)
G95_MAX=$(echo "$G95" | cut -d'|' -f2)
G95_AVG=$(echo "$G95" | cut -d'|' -f3)
G95_VALIDOS=$(cantidad_precio_valido 'Precio Gasolina 95 E5')
G95_VALENCIA_MIN=$(echo "$G95_VALENCIA" | cut -d'|' -f1)
G95_VALENCIA_MAX=$(echo "$G95_VALENCIA" | cut -d'|' -f2)
G95_VALENCIA_AVG=$(echo "$G95_VALENCIA" | cut -d'|' -f3)

G98_MIN=$(echo "$G98" | cut -d'|' -f1)
G98_MAX=$(echo "$G98" | cut -d'|' -f2)
G98_AVG=$(echo "$G98" | cut -d'|' -f3)
G98_VALIDOS=$(cantidad_precio_valido 'Precio Gasolina 98 E5')
G98_VALENCIA_MIN=$(echo "$G98_VALENCIA" | cut -d'|' -f1)
G98_VALENCIA_MAX=$(echo "$G98_VALENCIA" | cut -d'|' -f2)
G98_VALENCIA_AVG=$(echo "$G98_VALENCIA" | cut -d'|' -f3)

GASOLEO_MIN=$(echo "$GASOLEO" | cut -d'|' -f1)
GASOLEO_MAX=$(echo "$GASOLEO" | cut -d'|' -f2)
GASOLEO_AVG=$(echo "$GASOLEO" | cut -d'|' -f3)
GASOLEO_VALIDOS=$(cantidad_precio_valido 'Precio Gasoleo A')
GASOLEO_VALENCIA_MIN=$(echo "$GASOLEO_VALENCIA" | cut -d'|' -f1)
GASOLEO_VALENCIA_MAX=$(echo "$GASOLEO_VALENCIA" | cut -d'|' -f2)
GASOLEO_VALENCIA_AVG=$(echo "$GASOLEO_VALENCIA" | cut -d'|' -f3)

TOTAL_VALENCIA=$(jq '[.ListaEESSPrecio[] | select(.Provincia == "VALENCIA / VALÈNCIA")] | length' "$ARCHIVO_SALIDA")

# Informacion de la estacion donde aparece cada minimo y maximo.
G95_GLOBAL_MIN_INFO="$(estacion_extrema 'Precio Gasolina 95 E5' 'min')"
G95_GLOBAL_MAX_INFO="$(estacion_extrema 'Precio Gasolina 95 E5' 'max')"
G98_GLOBAL_MIN_INFO="$(estacion_extrema 'Precio Gasolina 98 E5' 'min')"
G98_GLOBAL_MAX_INFO="$(estacion_extrema 'Precio Gasolina 98 E5' 'max')"
GSO_GLOBAL_MIN_INFO="$(estacion_extrema 'Precio Gasoleo A' 'min')"
GSO_GLOBAL_MAX_INFO="$(estacion_extrema 'Precio Gasoleo A' 'max')"

G95_VALENCIA_MIN_INFO="$(estacion_extrema 'Precio Gasolina 95 E5' 'min' 'VALENCIA / VALÈNCIA')"
G95_VALENCIA_MAX_INFO="$(estacion_extrema 'Precio Gasolina 95 E5' 'max' 'VALENCIA / VALÈNCIA')"
G98_VALENCIA_MIN_INFO="$(estacion_extrema 'Precio Gasolina 98 E5' 'min' 'VALENCIA / VALÈNCIA')"
G98_VALENCIA_MAX_INFO="$(estacion_extrema 'Precio Gasolina 98 E5' 'max' 'VALENCIA / VALÈNCIA')"
GSO_VALENCIA_MIN_INFO="$(estacion_extrema 'Precio Gasoleo A' 'min' 'VALENCIA / VALÈNCIA')"
GSO_VALENCIA_MAX_INFO="$(estacion_extrema 'Precio Gasoleo A' 'max' 'VALENCIA / VALÈNCIA')"

IFS='|' read -r G95_GMIN_P G95_GMIN_N G95_GMIN_PR G95_GMIN_M G95_GMIN_D <<< "$G95_GLOBAL_MIN_INFO"
IFS='|' read -r G95_GMAX_P G95_GMAX_N G95_GMAX_PR G95_GMAX_M G95_GMAX_D <<< "$G95_GLOBAL_MAX_INFO"
IFS='|' read -r G98_GMIN_P G98_GMIN_N G98_GMIN_PR G98_GMIN_M G98_GMIN_D <<< "$G98_GLOBAL_MIN_INFO"
IFS='|' read -r G98_GMAX_P G98_GMAX_N G98_GMAX_PR G98_GMAX_M G98_GMAX_D <<< "$G98_GLOBAL_MAX_INFO"
IFS='|' read -r GSO_GMIN_P GSO_GMIN_N GSO_GMIN_PR GSO_GMIN_M GSO_GMIN_D <<< "$GSO_GLOBAL_MIN_INFO"
IFS='|' read -r GSO_GMAX_P GSO_GMAX_N GSO_GMAX_PR GSO_GMAX_M GSO_GMAX_D <<< "$GSO_GLOBAL_MAX_INFO"

IFS='|' read -r G95_VMIN_P G95_VMIN_N G95_VMIN_PR G95_VMIN_M G95_VMIN_D <<< "$G95_VALENCIA_MIN_INFO"
IFS='|' read -r G95_VMAX_P G95_VMAX_N G95_VMAX_PR G95_VMAX_M G95_VMAX_D <<< "$G95_VALENCIA_MAX_INFO"
IFS='|' read -r G98_VMIN_P G98_VMIN_N G98_VMIN_PR G98_VMIN_M G98_VMIN_D <<< "$G98_VALENCIA_MIN_INFO"
IFS='|' read -r G98_VMAX_P G98_VMAX_N G98_VMAX_PR G98_VMAX_M G98_VMAX_D <<< "$G98_VALENCIA_MAX_INFO"
IFS='|' read -r GSO_VMIN_P GSO_VMIN_N GSO_VMIN_PR GSO_VMIN_M GSO_VMIN_D <<< "$GSO_VALENCIA_MIN_INFO"
IFS='|' read -r GSO_VMAX_P GSO_VMAX_N GSO_VMAX_PR GSO_VMAX_M GSO_VMAX_D <<< "$GSO_VALENCIA_MAX_INFO"

TOP5="$(top5_valencia 'Precio Gasolina 95 E5')"
TOP5_VALENCIA=$(printf '%s\n' "$TOP5" | awk 'NF' | wc -l)

log "Gasolina 95 E5: $G95_VALIDOS precios válidos en el dataset completo."
log "Gasolina 98 E5: $G98_VALIDOS precios válidos en el dataset completo."
log "Gasóleo A: $GASOLEO_VALIDOS precios válidos en el dataset completo."
log "Registros de Valencia: $TOTAL_VALENCIA."
log "Top 5 Valencia calculado: $TOP5_VALENCIA estaciones."

# ------------------------------------------------------------
# 5. INFORME TXT
# ------------------------------------------------------------
log "Generando informe TXT..."

{
    echo "============================================================"
    echo "INFORME DIARIO DE PRECIOS DE CARBURANTES"
    echo "============================================================"
    echo "Fecha de datos: $FECHA_DIA"
    echo "Fecha de ejecución: $FECHA_HORA"
    echo "Dataset: $(basename "$ARCHIVO_SALIDA")"
    echo
    echo "RESUMEN DEL DATASET"
    echo "------------------------------------------------------------"
    echo "Total de estaciones: $TOTAL_REGISTROS"
    echo
    echo "GASOLINA 95 E5 (DATASET COMPLETO)"
    echo "Precios válidos: $G95_VALIDOS"
    echo "Mínimo:          $G95_MIN €/L"
    echo "Máximo:          $G95_MAX €/L"
    echo "Promedio:        $G95_AVG €/L"
    echo
    echo "GASOLINA 95 E5 (VALENCIA)"
    echo "Mínimo:          $G95_VALENCIA_MIN €/L"
    echo "Máximo:          $G95_VALENCIA_MAX €/L"
    echo "Promedio:        $G95_VALENCIA_AVG €/L"
    echo
    echo "GASOLINA 98 E5"
    echo "Precios válidos: $G98_VALIDOS"
    echo "Mínimo:          $G98_MIN €/L"
    echo "Máximo:          $G98_MAX €/L"
    echo "Promedio:        $G98_AVG €/L"
    echo
    echo "GASÓLEO A"
    echo "Precios válidos: $GASOLEO_VALIDOS"
    echo "Mínimo:          $GASOLEO_MIN €/L"
    echo "Máximo:          $GASOLEO_MAX €/L"
    echo "Promedio:        $GASOLEO_AVG €/L"
    echo
    echo "TOP 5 GASOLINERAS MÁS BARATAS DE VALENCIA"
    echo "(Gasolina 95 E5)"
    echo "------------------------------------------------------------"
    if [ "$TOP5_VALENCIA" -eq 0 ]; then
        echo "No se encontraron estaciones con precio válido."
    else
        printf '%s\n' "$TOP5" | awk -F'\t' '{print NR ". " $1 " €/L - " $2 " | " $3 " | " $4}'
    fi
    echo
    echo "============================================================"
} > "$INFORME_TXT"

# ------------------------------------------------------------
# 6. INFORME HTML
# ------------------------------------------------------------
log "Generando informe HTML..."

cat > "$INFORME_HTML" <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Informe de precios de carburantes - $FECHA_DIA</title>
<style>
:root{--bg:#f4f6f8;--card:#fff;--soft:#f8fafc;--line:#e5e7eb;--text:#182230;--muted:#667085;--blue:#2557d6;--blueSoft:#eef3ff;--green:#167a5d;--greenSoft:#eaf8f1;--shadow:0 8px 25px rgba(15,23,42,.06)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Arial,Helvetica,sans-serif;line-height:1.45}.wrap{max-width:1180px;margin:auto;padding:34px 20px 48px}
.header{margin-bottom:30px}.eyebrow{text-transform:uppercase;letter-spacing:.08em;font-size:12px;font-weight:700;color:var(--blue);margin-bottom:7px}h1{font-size:34px;margin:0 0 8px;line-height:1.15}h2{font-size:23px;margin:0 0 7px}h3{font-size:17px;margin:0}.meta,.intro{color:var(--muted);font-size:14px}.section{margin-top:32px}.intro{margin:0 0 17px;max-width:920px}
.badge{display:inline-block;padding:5px 10px;border-radius:999px;background:var(--blueSoft);color:var(--blue);font-size:11px;font-weight:700;white-space:nowrap}.badge.green{background:var(--greenSoft);color:var(--green)}
.total{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:17px 20px;box-shadow:var(--shadow);margin-bottom:16px}.total-number{font-size:30px;font-weight:800;margin-top:3px}.total-label{font-size:13px;color:var(--muted)}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}.card{background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);padding:19px}.head{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:16px}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:15px}.stat{background:var(--soft);border-radius:10px;padding:10px}.label{font-size:11px;color:var(--muted)}.value{font-size:19px;font-weight:800;margin-top:2px}
.extremes{border-top:1px solid var(--line);padding-top:10px}.extreme{display:grid;grid-template-columns:66px 1fr;gap:7px;padding:8px 0}.extreme+.extreme{border-top:1px dashed var(--line)}.kind{font-size:10px;text-transform:uppercase;color:var(--muted);font-weight:700;padding-top:2px}.station{font-size:13px;font-weight:700}.place{font-size:12px;color:var(--muted)}
.note{margin-top:15px;background:#fff6e8;border:1px solid #f2dfbd;border-radius:12px;padding:13px 15px;color:#714a00;font-size:13px}
.val-head{display:flex;justify-content:space-between;align-items:flex-end;gap:15px;margin-bottom:16px}.val-card{padding:19px}.val-extremes{display:grid;grid-template-columns:1fr 1fr;gap:9px}.val-box{background:var(--soft);padding:12px;border-radius:10px}.val-kind{font-size:10px;text-transform:uppercase;color:var(--muted);font-weight:700}.val-price{font-size:20px;font-weight:800;margin:3px 0 4px}
.ranking{background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);overflow:hidden}.ranking-head{padding:18px 20px;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;align-items:center;gap:14px}.ranking-head p{margin:3px 0 0;color:var(--muted);font-size:13px}.rank{font-weight:800;color:var(--blue);width:42px}.price{font-weight:800;white-space:nowrap}.address{font-size:12px;color:var(--muted)}table{width:100%;border-collapse:collapse}th,td{padding:13px 15px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{background:var(--soft);color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em}td{font-size:14px}tbody tr:last-child td{border-bottom:none}
.footer{margin-top:16px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;color:var(--muted);font-size:13px}.source{margin-top:7px;font-size:12px;color:var(--muted)}
@media(max-width:920px){.grid3{grid-template-columns:1fr}.val-head{display:block}}@media(max-width:650px){.wrap{padding:24px 12px 36px}h1{font-size:28px}.stats{grid-template-columns:1fr}.val-extremes{grid-template-columns:1fr}.ranking{overflow-x:auto}.ranking table{min-width:760px}.ranking-head{display:block}}
</style>
</head>
<body>
<div class="wrap">
<header class="header"><div class="eyebrow">Monitorización de carburantes</div><h1>Informe diario de precios</h1><p class="meta">Datos del $FECHA_DIA · Ejecución $FECHA_HORA · $(basename "$ARCHIVO_SALIDA")</p></header>

<section class="section">
<h2>1. Visión general del dataset</h2>
<p class="intro">Primero se presenta una visión general de todos los registros. Los extremos muestran también dónde se encontró el precio, para que la cifra tenga contexto geográfico.</p>
<div class="total"><span class="badge">Dataset completo</span><div class="total-number">$TOTAL_REGISTROS</div><div class="total-label">estaciones de servicio registradas</div></div>
<div class="grid3">
<article class="card"><div class="head"><h3>Gasolina 95 E5</h3><span class="badge">General</span></div><div class="stats"><div class="stat"><div class="label">Mínimo</div><div class="value">$G95_MIN €/L</div></div><div class="stat"><div class="label">Promedio</div><div class="value">$G95_AVG €/L</div></div><div class="stat"><div class="label">Máximo</div><div class="value">$G95_MAX €/L</div></div></div><div class="extremes"><div class="extreme"><div class="kind">Mínimo</div><div><div class="station">$G95_GMIN_N</div><div class="place">$G95_GMIN_M · $G95_GMIN_PR<br>$G95_GMIN_D</div></div></div><div class="extreme"><div class="kind">Máximo</div><div><div class="station">$G95_GMAX_N</div><div class="place">$G95_GMAX_M · $G95_GMAX_PR<br>$G95_GMAX_D</div></div></div></div></article>
<article class="card"><div class="head"><h3>Gasolina 98 E5</h3><span class="badge">General</span></div><div class="stats"><div class="stat"><div class="label">Mínimo</div><div class="value">$G98_MIN €/L</div></div><div class="stat"><div class="label">Promedio</div><div class="value">$G98_AVG €/L</div></div><div class="stat"><div class="label">Máximo</div><div class="value">$G98_MAX €/L</div></div></div><div class="extremes"><div class="extreme"><div class="kind">Mínimo</div><div><div class="station">$G98_GMIN_N</div><div class="place">$G98_GMIN_M · $G98_GMIN_PR<br>$G98_GMIN_D</div></div></div><div class="extreme"><div class="kind">Máximo</div><div><div class="station">$G98_GMAX_N</div><div class="place">$G98_GMAX_M · $G98_GMAX_PR<br>$G98_GMAX_D</div></div></div></div></article>
<article class="card"><div class="head"><h3>Gasóleo A</h3><span class="badge">General</span></div><div class="stats"><div class="stat"><div class="label">Mínimo</div><div class="value">$GASOLEO_MIN €/L</div></div><div class="stat"><div class="label">Promedio</div><div class="value">$GASOLEO_AVG €/L</div></div><div class="stat"><div class="label">Máximo</div><div class="value">$GASOLEO_MAX €/L</div></div></div><div class="extremes"><div class="extreme"><div class="kind">Mínimo</div><div><div class="station">$GSO_GMIN_N</div><div class="place">$GSO_GMIN_M · $GSO_GMIN_PR<br>$GSO_GMIN_D</div></div></div><div class="extreme"><div class="kind">Máximo</div><div><div class="station">$GSO_GMAX_N</div><div class="place">$GSO_GMAX_M · $GSO_GMAX_PR<br>$GSO_GMAX_D</div></div></div></div></article>
</div><div class="note"><strong>Cómo leer esta sección:</strong> los precios anteriores corresponden a todo el dataset y, por tanto, pueden pertenecer a distintas provincias. Esta información sirve como contexto general; el análisis principal continúa con Valencia.</div>
</section>

<section class="section">
<div class="val-head"><div><h2>2. Análisis específico de Valencia</h2><p class="intro">A partir de aquí solo se consideran estaciones cuya provincia es <strong>VALENCIA / VALÈNCIA</strong>. En cada combustible se identifica la estación más barata y la más cara.</p></div><span class="badge green">$TOTAL_VALENCIA estaciones</span></div>
<div class="grid3">
<article class="card val-card"><div class="head"><h3>Gasolina 95 E5</h3><span class="badge green">Valencia</span></div><div class="stats"><div class="stat"><div class="label">Mínimo</div><div class="value">$G95_VALENCIA_MIN €/L</div></div><div class="stat"><div class="label">Promedio</div><div class="value">$G95_VALENCIA_AVG €/L</div></div><div class="stat"><div class="label">Máximo</div><div class="value">$G95_VALENCIA_MAX €/L</div></div></div><div class="val-extremes"><div class="val-box"><div class="val-kind">Más barata</div><div class="val-price">$G95_VMIN_P €/L</div><div class="station">$G95_VMIN_N</div><div class="place">$G95_VMIN_M · $G95_VMIN_D</div></div><div class="val-box"><div class="val-kind">Más cara</div><div class="val-price">$G95_VMAX_P €/L</div><div class="station">$G95_VMAX_N</div><div class="place">$G95_VMAX_M · $G95_VMAX_D</div></div></div></article>
<article class="card val-card"><div class="head"><h3>Gasolina 98 E5</h3><span class="badge green">Valencia</span></div><div class="stats"><div class="stat"><div class="label">Mínimo</div><div class="value">$G98_VALENCIA_MIN €/L</div></div><div class="stat"><div class="label">Promedio</div><div class="value">$G98_VALENCIA_AVG €/L</div></div><div class="stat"><div class="label">Máximo</div><div class="value">$G98_VALENCIA_MAX €/L</div></div></div><div class="val-extremes"><div class="val-box"><div class="val-kind">Más barata</div><div class="val-price">$G98_VMIN_P €/L</div><div class="station">$G98_VMIN_N</div><div class="place">$G98_VMIN_M · $G98_VMIN_D</div></div><div class="val-box"><div class="val-kind">Más cara</div><div class="val-price">$G98_VMAX_P €/L</div><div class="station">$G98_VMAX_N</div><div class="place">$G98_VMAX_M · $G98_VMAX_D</div></div></div></article>
<article class="card val-card"><div class="head"><h3>Gasóleo A</h3><span class="badge green">Valencia</span></div><div class="stats"><div class="stat"><div class="label">Mínimo</div><div class="value">$GASOLEO_VALENCIA_MIN €/L</div></div><div class="stat"><div class="label">Promedio</div><div class="value">$GASOLEO_VALENCIA_AVG €/L</div></div><div class="stat"><div class="label">Máximo</div><div class="value">$GASOLEO_VALENCIA_MAX €/L</div></div></div><div class="val-extremes"><div class="val-box"><div class="val-kind">Más barata</div><div class="val-price">$GSO_VMIN_P €/L</div><div class="station">$GSO_VMIN_N</div><div class="place">$GSO_VMIN_M · $GSO_VMIN_D</div></div><div class="val-box"><div class="val-kind">Más cara</div><div class="val-price">$GSO_VMAX_P €/L</div><div class="station">$GSO_VMAX_N</div><div class="place">$GSO_VMAX_M · $GSO_VMAX_D</div></div></div></article>
</div>
</section>

<section class="section">
<h2>3. Top 5 gasolineras más baratas de Valencia</h2>
<p class="intro">Ranking de <strong>Gasolina 95 E5</strong>, ordenado de menor a mayor precio. El primer precio coincide con el mínimo de Gasolina 95 E5 de Valencia calculado arriba.</p>
<div class="ranking"><div class="ranking-head"><div><h3>Ranking local</h3><p>Provincia de Valencia · Gasolina 95 E5</p></div><span class="badge green">$TOP5_VALENCIA estaciones</span></div>
<table><thead><tr><th>#</th><th>Precio</th><th>Gasolinera</th><th>Municipio</th><th>Dirección</th></tr></thead><tbody>
EOF

if [ "$TOP5_VALENCIA" -gt 0 ]; then
    echo "$TOP5" | awk -F'\t' '{printf "<tr><td class=\"rank\">%d</td><td class=\"price\">%s €/L</td><td><div class=\"station\">%s</div></td><td>%s</td><td class=\"address\">%s</td></tr>\n", NR, $1, $2, $3, $4}' >> "$INFORME_HTML"
else
    echo '<tr><td colspan="5">No se encontraron estaciones con precio válido en Valencia.</td></tr>' >> "$INFORME_HTML"
fi

cat >> "$INFORME_HTML" <<EOF
</tbody></table></div>
<div class="footer"><strong>Metodología:</strong> se ignoran valores vacíos o nulos, se convierten las comas decimales a puntos y se descartan precios menores o iguales a cero. El análisis de Valencia y el Top 5 se calculan exclusivamente con registros de <strong>VALENCIA / VALÈNCIA</strong>.<div class="source">Los precios corresponden al momento de generación del dataset descargado por el script.</div></div>
</section>
</div></body></html>
EOF

# ------------------------------------------------------------
# 7. ELIMINACIÓN DE DATASETS ANTIGUOS
# ------------------------------------------------------------
log "Eliminando datasets con más de $DIAS_RETENCION días..."
find "$CARPETA_DATASETS" -type f -name 'precios_gasolineras_*.json' -mtime +"$DIAS_RETENCION" -print -delete >> "$LOG" 2>&1

log "Informes generados: $(basename "$INFORME_TXT") y $(basename "$INFORME_HTML")"
log "Ejecución finalizada correctamente."
