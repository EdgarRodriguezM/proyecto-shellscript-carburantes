const ARCHIVO_DATOS = window.location.hostname.includes("github.io")
    ? "./historico/precios_historicos.csv"
    : "../historico/precios_historicos.csv";

let datosHistoricos = [];
let estaciones = [];
let resultadosActuales = [];
let mapa = null;
let marcadores = [];
let marcadorPorId = new Map();
let chartHistorico = null;

const provinciaSelect = document.getElementById("provincia");
const municipioSelect = document.getElementById("municipio");
const combustibleSelect = document.getElementById("combustible");
const combustibleEspana = document.getElementById("combustible-espana");
const buscarButton = document.getElementById("buscar");
const ordenSelect = document.getElementById("orden");
const historialEstacion = document.getElementById("historial-estacion");

const estado = document.getElementById("estado");
const headerStatus = document.getElementById("header-status-text");
const footerUpdate = document.getElementById("footer-update");
const resultadosSection = document.getElementById("resultados-section");
const historySection = document.getElementById("history-section");
const tituloResultados = document.getElementById("titulo-resultados");
const contadorResultados = document.getElementById("contador-resultados");
const resultadosBadge = document.getElementById("resultados-count-badge");
const listaResultados = document.getElementById("lista-resultados");
const precioMinimo = document.getElementById("precio-minimo");
const precioMedio = document.getElementById("precio-medio");
const precioMaximo = document.getElementById("precio-maximo");
const topEspana = document.getElementById("top-espana");

const historialNombre = document.getElementById("historial-nombre");
const historialUbicacion = document.getElementById("historial-ubicacion");
const historialActual = document.getElementById("historial-actual");
const historialDias = document.getElementById("historial-dias");
const historialMin = document.getElementById("historial-min");
const historialMax = document.getElementById("historial-max");
const historialVariacion = document.getElementById("historial-variacion");
const historyEmpty = document.getElementById("history-empty");


document.addEventListener("DOMContentLoaded", cargarDatos);

async function cargarDatos() {
    try {
        estado.textContent = "Cargando los datos más recientes...";
        const respuesta = await fetch(ARCHIVO_DATOS, { cache: "no-store" });

        if (!respuesta.ok) {
            throw new Error("No se pudo cargar el archivo histórico.");
        }

        const texto = await respuesta.text();
        datosHistoricos = parseCSV(texto);

        if (!datosHistoricos.length) {
            throw new Error("El archivo histórico no contiene registros.");
        }

        estaciones = obtenerUltimaActualizacion(datosHistoricos);
        cargarProvincias();
        mostrarTopEspana();

        const fecha = obtenerFechaMasReciente(estaciones);
        const fechaTexto = formatearFecha(fecha);

        estado.textContent = `${estaciones.length.toLocaleString("es-ES")} estaciones disponibles · última actualización ${fechaTexto}.`;
        headerStatus.textContent = `Actualizado ${fechaTexto}`;
        footerUpdate.textContent = `Última actualización: ${fechaTexto}`;
    } catch (error) {
        console.error(error);
        estado.textContent = "No se pudieron cargar los datos. Comprueba que historico/precios_historicos.csv está disponible.";
        estado.classList.add("error");
        headerStatus.textContent = "Error al cargar datos";
    }
}

function obtenerUltimaActualizacion(datos) {
    const mapaEstaciones = new Map();

    datos.forEach(estacion => {
        const id = (estacion.IDEESS || "").trim();
        if (!id) return;
        const existente = mapaEstaciones.get(id);
        if (!existente || (estacion.fecha || "") > (existente.fecha || "")) {
            mapaEstaciones.set(id, estacion);
        }
    });

    return Array.from(mapaEstaciones.values());
}

function obtenerFechaMasReciente(datos) {
    return datos.reduce((max, estacion) => ((estacion.fecha || "") > max ? estacion.fecha : max), "");
}

function formatearFecha(fecha) {
    if (!fecha) return "fecha desconocida";
    const partes = fecha.split("-");
    if (partes.length !== 3) return fecha;
    return `${partes[2]}/${partes[1]}/${partes[0]}`;
}

function parseCSV(texto) {
    const lineas = texto.trim().split(/\r?\n/);
    if (lineas.length < 2) return [];

    const encabezados = parseCSVLine(lineas[0]);
    const datos = [];

    for (let i = 1; i < lineas.length; i++) {
        if (!lineas[i].trim()) continue;
        const valores = parseCSVLine(lineas[i]);
        const fila = {};

        encabezados.forEach((encabezado, indice) => {
            fila[encabezado] = valores[indice] !== undefined ? valores[indice].trim() : "";
        });

        datos.push(fila);
    }

    return datos;
}

function parseCSVLine(linea) {
    const resultado = [];
    let campo = "";
    let dentroComillas = false;

    for (let i = 0; i < linea.length; i++) {
        const caracter = linea[i];

        if (caracter === '"') {
            if (dentroComillas && linea[i + 1] === '"') {
                campo += '"';
                i++;
            } else {
                dentroComillas = !dentroComillas;
            }
        } else if (caracter === "," && !dentroComillas) {
            resultado.push(campo);
            campo = "";
        } else {
            campo += caracter;
        }
    }

    resultado.push(campo);
    return resultado;
}

function cargarProvincias() {
    const provincias = [...new Set(estaciones.map(e => e.provincia).filter(Boolean))];
    provincias.sort((a, b) => a.localeCompare(b, "es"));

    provinciaSelect.innerHTML = '<option value="">Selecciona una provincia</option>';

    provincias.forEach(provincia => {
        const option = document.createElement("option");
        option.value = provincia;
        option.textContent = provincia;
        provinciaSelect.appendChild(option);
    });
}

provinciaSelect.addEventListener("change", cargarMunicipios);

function cargarMunicipios() {
    const provincia = provinciaSelect.value;
    municipioSelect.innerHTML = '<option value="">Todos los municipios</option>';

    if (!provincia) {
        municipioSelect.disabled = true;
        return;
    }

    const municipios = [
        ...new Set(
            estaciones
                .filter(e => e.provincia === provincia)
                .map(e => e.municipio)
                .filter(Boolean)
        )
    ];

    municipios.sort((a, b) => a.localeCompare(b, "es"));

    municipios.forEach(municipio => {
        const option = document.createElement("option");
        option.value = municipio;
        option.textContent = municipio;
        municipioSelect.appendChild(option);
    });

    municipioSelect.disabled = false;
}

buscarButton.addEventListener("click", buscarGasolineras);

function buscarGasolineras() {
    const provincia = provinciaSelect.value;
    const municipio = municipioSelect.value;
    const combustible = combustibleSelect.value;

    if (!provincia) {
        alert("Selecciona una provincia para realizar la búsqueda.");
        provinciaSelect.focus();
        return;
    }

    let resultados = estaciones.filter(e => e.provincia === provincia);

    if (municipio) {
        resultados = resultados.filter(e => e.municipio === municipio);
    }

    resultados = resultados.filter(e => obtenerPrecio(e, combustible) !== null);
    resultados = ordenarResultados(resultados, combustible);
    resultadosActuales = resultados;

    mostrarResultados(resultados, provincia, municipio, combustible);
    mostrarMapa(resultados, combustible);
    prepararSelectorHistorial(resultados, combustible);

    resultadosSection.scrollIntoView({ behavior: "smooth", block: "start" });
}

function obtenerPrecio(estacion, combustible) {
    const valor = estacion[combustible];
    if (valor === undefined || valor === null || valor.trim() === "") return null;

    const precio = parseFloat(valor.replace(/\s/g, "").replace(",", "."));
    if (!Number.isFinite(precio) || precio <= 0) return null;
    return precio;
}

function ordenarResultados(resultados, combustible) {
    const copia = [...resultados];
    copia.sort((a, b) => {
        const precioA = obtenerPrecio(a, combustible);
        const precioB = obtenerPrecio(b, combustible);
        return ordenSelect.value === "desc" ? precioB - precioA : precioA - precioB;
    });
    return copia;
}

ordenSelect.addEventListener("change", () => {
    if (!resultadosSection.classList.contains("hidden") && provinciaSelect.value) {
        buscarGasolineras();
    }
});

function mostrarResultados(resultados, provincia, municipio, combustible) {
    listaResultados.innerHTML = "";
    const nombreCarburante = nombreCombustible(combustible);
    let ubicacion = provincia;
    if (municipio) ubicacion += ` · ${municipio}`;

    tituloResultados.textContent = `Gasolineras en ${ubicacion}`;
    contadorResultados.textContent = `${resultados.length.toLocaleString("es-ES")} estaciones con precio disponible para ${nombreCarburante}.`;
    resultadosBadge.textContent = resultados.length.toLocaleString("es-ES");

    if (!resultados.length) {
        precioMinimo.textContent = "—";
        precioMedio.textContent = "—";
        precioMaximo.textContent = "—";
        listaResultados.innerHTML = '<div class="station-card"><div class="station-main"><p class="station-name">No hay precios disponibles.</p><p class="station-location">Prueba otro carburante o municipio.</p></div></div>';
        resultadosSection.classList.remove("hidden");
        return;
    }

    actualizarResumen(resultados, combustible);

    resultados.forEach((estacion, indice) => crearTarjeta(estacion, indice, combustible));
    resultadosSection.classList.remove("hidden");
}

function actualizarResumen(resultados, combustible) {
    const precios = resultados.map(e => obtenerPrecio(e, combustible)).filter(p => p !== null);
    const minimo = Math.min(...precios);
    const maximo = Math.max(...precios);
    const media = precios.reduce((total, p) => total + p, 0) / precios.length;
    precioMinimo.textContent = formatearPrecio(minimo);
    precioMedio.textContent = formatearPrecio(media);
    precioMaximo.textContent = formatearPrecio(maximo);
}

function crearTarjeta(estacion, indice, combustible) {
    const precio = obtenerPrecio(estacion, combustible);
    const tarjeta = document.createElement("article");
    tarjeta.className = "station-card";
    tarjeta.dataset.id = estacion.IDEESS || "";

    let posicion = String(indice + 1);
    let claseRank = "rank";
    if (indice === 0) { posicion = "🥇"; claseRank += " medal"; }
    else if (indice === 1) { posicion = "🥈"; claseRank += " medal"; }
    else if (indice === 2) { posicion = "🥉"; claseRank += " medal"; }

    const direccion = estacion.direccion || "Dirección no disponible en este registro.";

    tarjeta.innerHTML = `
        <div class="${claseRank}">${posicion}</div>
        <div class="station-main">
            <h3 class="station-name">${escaparHTML(estacion.rotulo || "Gasolinera")}</h3>
            <p class="station-location">${escaparHTML(estacion.municipio || "Municipio no indicado")} · ${escaparHTML(estacion.provincia || "")}</p>
            <p class="station-address">${escaparHTML(direccion)}</p>
        </div>
        <div class="station-price">
            <strong>${formatearPrecio(precio)}</strong>
            <span>por litro</span>
        </div>
    `;

    tarjeta.addEventListener("click", () => {
        enfocarEstacionEnMapa(estacion.IDEESS);
        seleccionarHistorial(estacion.IDEESS);
    });

    listaResultados.appendChild(tarjeta);
}

function iniciarMapa() {
    if (mapa) return;

    mapa = L.map("map", { scrollWheelZoom: false }).setView([40.4168, -3.7038], 6);

    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).addTo(mapa);
}

function mostrarMapa(resultados, combustible) {
    iniciarMapa();

    marcadores.forEach(marcador => mapa.removeLayer(marcador));
    marcadores = [];
    marcadorPorId = new Map();

    const estacionesMapa = resultados.filter(e => obtenerCoordenadas(e) !== null);

    if (!estacionesMapa.length) {
        setTimeout(() => mapa.invalidateSize(true), 100);
        return;
    }

    const limites = [];

    estacionesMapa.forEach(estacion => {
        const coordenadas = obtenerCoordenadas(estacion);
        const precio = obtenerPrecio(estacion, combustible);
        const marcador = L.marker(coordenadas).addTo(mapa);
        const direccion = estacion.direccion || "Dirección no disponible en este registro.";

        marcador.bindPopup(`
            <div class="popup-name">${escaparHTML(estacion.rotulo || "Gasolinera")}</div>
            <div>${escaparHTML(estacion.municipio || "")} · ${escaparHTML(estacion.provincia || "")}</div>
            <div>${escaparHTML(direccion)}</div>
            <div class="popup-price">${formatearPrecio(precio)}</div>
        `);

        marcadores.push(marcador);
        marcadorPorId.set(estacion.IDEESS, marcador);
        limites.push(coordenadas);
    });

    mapa.fitBounds(limites, { padding: [30, 30] });
    setTimeout(() => mapa.invalidateSize(true), 250);
}

function enfocarEstacionEnMapa(id) {
    const marcador = marcadorPorId.get(id);

    if (!marcador || !mapa) return;

    const posicion = marcador.getLatLng();

    mapa.setView(posicion, Math.max(mapa.getZoom(), 15), {
        animate: true
    });

    marcador.openPopup();

    document.querySelectorAll(".station-card").forEach(card => {
        card.classList.remove("is-selected");
    });

    const tarjeta = document.querySelector(
        `.station-card[data-id="${CSS.escape(id || "")}"]`
    );

    if (tarjeta) {
        tarjeta.classList.add("is-selected");
    }

    const panelMapa = document.getElementById("map-section");

    if (panelMapa) {
        panelMapa.scrollIntoView({
            behavior: "smooth",
            block: "center"
        });
    }
}

function obtenerCoordenadas(estacion) {
    if (!estacion.latitud || !estacion.longitud) return null;
    const lat = parseFloat(estacion.latitud.replace(",", "."));
    const lon = parseFloat(estacion.longitud.replace(",", "."));
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return [lat, lon];
}

/* =========================
   HISTÓRICO
========================= */

function prepararSelectorHistorial(resultados, combustible) {
    historialEstacion.innerHTML = "";

    resultados.forEach(estacion => {
        const option = document.createElement("option");
        option.value = estacion.IDEESS || "";
        option.textContent = `${estacion.rotulo || "Gasolinera"} · ${estacion.municipio || ""} · ${formatearPrecio(obtenerPrecio(estacion, combustible))}`;
        historialEstacion.appendChild(option);
    });

    if (resultados.length) {
        historialEstacion.value = resultados[0].IDEESS || "";
        actualizarHistorial(resultados[0].IDEESS, combustible);
        historySection.classList.remove("hidden");
    }
}

historialEstacion.addEventListener("change", () => {
    actualizarHistorial(historialEstacion.value, combustibleSelect.value);
});

function seleccionarHistorial(id) {
    if (!id || !historialEstacion.options.length) return;
    const existe = Array.from(historialEstacion.options).some(option => option.value === id);
    if (!existe) return;
    historialEstacion.value = id;
    actualizarHistorial(id, combustibleSelect.value);
    // La selección actualiza el histórico, pero no desplaza la página hacia él.
}

function actualizarHistorial(id, combustible) {
    const estacionActual = estaciones.find(e => e.IDEESS === id);
    if (!estacionActual) return;

    const registros = datosHistoricos
        .filter(e => e.IDEESS === id)
        .map(e => {
            const precio = obtenerPrecio(e, combustible);
            return precio === null ? null : { fecha: e.fecha, precio, estacion: e };
        })
        .filter(Boolean)
        .sort((a, b) => a.fecha.localeCompare(b.fecha));

    historialNombre.textContent = estacionActual.rotulo || "Gasolinera";
    historialUbicacion.textContent = `${estacionActual.municipio || ""} · ${estacionActual.provincia || ""}${estacionActual.direccion ? ` · ${estacionActual.direccion}` : ""}`;

    const precioActual = obtenerPrecio(estacionActual, combustible);
    historialActual.textContent = precioActual === null ? "—" : formatearPrecio(precioActual);

    historialDias.textContent = registros.length.toLocaleString("es-ES");

    if (!registros.length) {
        historialMin.textContent = "—";
        historialMax.textContent = "—";
        historialVariacion.textContent = "—";
        mostrarMensajeHistorial("No hay precios históricos disponibles para este carburante en esta estación.");
        return;
    }

    const precios = registros.map(r => r.precio);
    historialMin.textContent = formatearPrecio(Math.min(...precios));
    historialMax.textContent = formatearPrecio(Math.max(...precios));

    const primero = registros[0].precio;
    const ultimo = registros[registros.length - 1].precio;

    if (registros.length < 2) {
        historialVariacion.textContent = "—";
    } else {
        const diferencia = ultimo - primero;
        const porcentaje = primero !== 0 ? (diferencia / primero) * 100 : 0;
        historialVariacion.textContent = `${diferencia >= 0 ? "+" : ""}${diferencia.toFixed(3).replace(".", ",")} € (${porcentaje >= 0 ? "+" : ""}${porcentaje.toFixed(2).replace(".", ",")}%)`;
    }

    mostrarGraficaHistorial(registros, combustible);
}

function mostrarMensajeHistorial(texto) {
    if (chartHistorico) {
        chartHistorico.destroy();
        chartHistorico = null;
    }
    historyEmpty.textContent = texto;
    historyEmpty.classList.remove("hidden");
}

function mostrarGraficaHistorial(registros, combustible) {
    historyEmpty.classList.add("hidden");

    const labels = registros.map(r => formatearFecha(r.fecha));
    const valores = registros.map(r => r.precio);

    if (chartHistorico) chartHistorico.destroy();

    const contexto = document.getElementById("history-chart").getContext("2d");

    chartHistorico = new Chart(contexto, {
        type: "line",
        data: {
            labels,
            datasets: [{
                label: nombreCombustible(combustible),
                data: valores,
                borderWidth: 3,
                tension: 0.28,
                fill: true,
                pointRadius: registros.length <= 12 ? 4 : 2,
                pointHoverRadius: 6
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { intersect: false, mode: "index" },
            plugins: {
                legend: { display: false },
                tooltip: {
                    callbacks: {
                        label: context => `${context.parsed.y.toFixed(3).replace(".", ",")} €/L`
                    }
                }
            },
            scales: {
                y: {
                    beginAtZero: false,
                    ticks: {
                        callback: value => `${Number(value).toFixed(3).replace(".", ",")} €`
                    }
                }
            }
        }
    });
}

/* =========================
   TOP ESPAÑA
========================= */

combustibleEspana.addEventListener("change", mostrarTopEspana);

function mostrarTopEspana() {
    const combustible = combustibleEspana.value;
    let resultados = estaciones.filter(e => obtenerPrecio(e, combustible) !== null);
    resultados = ordenarResultados(resultados, combustible).slice(0, 10);
    topEspana.innerHTML = "";

    resultados.forEach((estacion, indice) => {
        const precio = obtenerPrecio(estacion, combustible);
        const card = document.createElement("article");
        card.className = "national-card";

        let posicion = String(indice + 1);
        let claseRank = "national-rank";
        if (indice === 0) { posicion = "🥇"; claseRank += " medal"; }
        else if (indice === 1) { posicion = "🥈"; claseRank += " medal"; }
        else if (indice === 2) { posicion = "🥉"; claseRank += " medal"; }

        card.innerHTML = `
            <div class="${claseRank}">${posicion}</div>
            <div class="national-info">
                <strong>${escaparHTML(estacion.rotulo || "Gasolinera")}</strong>
                <span>${escaparHTML(estacion.municipio || "")} · ${escaparHTML(estacion.provincia || "")}</span>
            </div>
            <div class="national-price">${formatearPrecio(precio)}</div>
        `;

        topEspana.appendChild(card);
    });
}

function nombreCombustible(combustible) {
    switch (combustible) {
        case "gasolina95": return "Gasolina 95";
        case "gasolina98": return "Gasolina 98";
        case "gasoleoA": return "Gasóleo A";
        default: return "Carburante";
    }
}

function formatearPrecio(precio) {
    if (precio === null || precio === undefined || !Number.isFinite(precio)) return "—";
    return precio.toLocaleString("es-ES", { minimumFractionDigits: 3, maximumFractionDigits: 3 }) + " €/L";
}

function escaparHTML(texto) {
    return String(texto)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}
