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
GASOLEO="$(estadisticas_precio 'Precio Gasoleo A')"

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

GASOLEO_MIN=$(echo "$GASOLEO" | cut -d'|' -f1)
GASOLEO_MAX=$(echo "$GASOLEO" | cut -d'|' -f2)
GASOLEO_AVG=$(echo "$GASOLEO" | cut -d'|' -f3)
GASOLEO_VALIDOS=$(cantidad_precio_valido 'Precio Gasoleo A')

TOP5=$(top5_valencia 'Precio Gasolina 95 E5')
TOP5_VALENCIA=$(printf '%s\n' "$TOP5" | awk 'NF' | wc -l)

log "Gasolina 95 E5: $G95_VALIDOS precios válidos en el dataset completo."
log "Gasolina 95 E5 Valencia: mínimo $G95_VALENCIA_MIN €/L."
log "Gasolina 98 E5: $G98_VALIDOS precios válidos."
log "Gasóleo A: $GASOLEO_VALIDOS precios válidos."
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
<title>Precios de carburantes - $FECHA_DIA</title>
<style>
body{font-family:Arial,Helvetica,sans-serif;background:#f4f6f8;color:#1f2937;margin:0;padding:30px}
.container{max-width:1000px;margin:auto;background:white;padding:30px;border-radius:12px}
h1{margin-top:0}.meta{color:#6b7280;margin-bottom:25px}
.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:15px;margin-bottom:30px}
.card{background:#f8fafc;border:1px solid #e5e7eb;border-radius:10px;padding:18px}
.card h2{font-size:16px;margin-top:0}.metric{margin:8px 0}.number{font-size:25px;font-weight:bold}
section{margin-top:30px}table{width:100%;border-collapse:collapse}th,td{padding:10px;border-bottom:1px solid #e5e7eb;text-align:left}th{background:#f3f4f6}
.note{background:#f9fafb;padding:14px;border-left:4px solid #9ca3af}
@media(max-width:700px){.cards{grid-template-columns:1fr}body{padding:10px}.container{padding:18px}}
</style>
</head>
<body>
<div class="container">
<h1>Informe diario de precios de carburantes</h1>
<p class="meta">Datos del $FECHA_DIA · Ejecutado el $FECHA_HORA</p>

<section>
<h2>Resumen</h2>
<p><strong>$TOTAL_REGISTROS</strong> estaciones de servicio en el dataset.</p>
</section>

<section>
<h2>Precios medios y extremos</h2>
<div class="cards">
  <div class="card"><h2>Gasolina 95 E5 · Dataset</h2><div class="metric">Mínimo<br><span class="number">$G95_MIN €/L</span></div><div class="metric">Promedio<br><span class="number">$G95_AVG €/L</span></div><div class="metric">Máximo<br><span class="number">$G95_MAX €/L</span></div><div class="metric">Válidos: $G95_VALIDOS</div></div>
  <div class="card"><h2>Gasolina 98 E5</h2><div class="metric">Mínimo<br><span class="number">$G98_MIN €/L</span></div><div class="metric">Promedio<br><span class="number">$G98_AVG €/L</span></div><div class="metric">Máximo<br><span class="number">$G98_MAX €/L</span></div><div class="metric">Válidos: $G98_VALIDOS</div></div>
  <div class="card"><h2>Gasóleo A</h2><div class="metric">Mínimo<br><span class="number">$GASOLEO_MIN €/L</span></div><div class="metric">Promedio<br><span class="number">$GASOLEO_AVG €/L</span></div><div class="metric">Máximo<br><span class="number">$GASOLEO_MAX €/L</span></div><div class="metric">Válidos: $GASOLEO_VALIDOS</div></div>
</div>
</section>

<section>
<h2>Gasolina 95 E5 en Valencia</h2>
<p>Mínimo: <strong>$G95_VALENCIA_MIN €/L</strong> · Promedio: <strong>$G95_VALENCIA_AVG €/L</strong> · Máximo: <strong>$G95_VALENCIA_MAX €/L</strong></p>
</section>

<section>
<h2>Top 5 gasolineras más baratas de Valencia</h2>
<p>Combustible analizado: <strong>Gasolina 95 E5</strong></p>
<table>
<thead><tr><th>#</th><th>Precio</th><th>Gasolinera</th><th>Municipio</th><th>Dirección</th></tr></thead>
<tbody>
EOF

if [ "$TOP5_VALENCIA" -gt 0 ]; then
    echo "$TOP5" | awk -F'\t' '{printf "<tr><td>%d</td><td><strong>%s €/L</strong></td><td>%s</td><td>%s</td><td>%s</td></tr>\n", NR, $1, $2, $3, $4}' >> "$INFORME_HTML"
else
    echo '<tr><td colspan="5">No se encontraron estaciones con precio válido.</td></tr>' >> "$INFORME_HTML"
fi

cat >> "$INFORME_HTML" <<EOF
</tbody>
</table>
</section>

<section>
<div class="note"><strong>Limpieza aplicada:</strong> se ignoraron valores vacíos o nulos, se convirtieron las comas decimales a puntos y se descartaron precios menores o iguales a cero.</div>
</section>

</div>
</body>
</html>
EOF

# ------------------------------------------------------------
# 7. ELIMINACIÓN DE DATASETS ANTIGUOS
# ------------------------------------------------------------
log "Eliminando datasets con más de $DIAS_RETENCION días..."
find "$CARPETA_DATASETS" -type f -name 'precios_gasolineras_*.json' -mtime +"$DIAS_RETENCION" -print -delete >> "$LOG" 2>&1

log "Informes generados: $(basename "$INFORME_TXT") y $(basename "$INFORME_HTML")"
log "Ejecución finalizada correctamente."
