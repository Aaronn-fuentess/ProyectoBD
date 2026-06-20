
-- SP 1: PROCESAR PRÉSTAMO
-- Valida ejemplar disponible, socio solvente, límite de 3 préstamos
-- activos y registra el préstamo actualizando el estado del ejemplar.
CREATE OR REPLACE PROCEDURE sp_procesar_prestamo(
    p_id_ejemplar  INT,
    p_id_socio     INT,
    p_id_empleado  INT,
    p_dias         INT DEFAULT 15
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_ejemplar   VARCHAR(20);
    v_solvente          BOOLEAN;
    v_prestamos_activos INT;
BEGIN
    -- 1. Verificar que el ejemplar existe y está disponible
    SELECT estado INTO v_estado_ejemplar
    FROM ejemplares
    WHERE id_ejemplar = p_id_ejemplar;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El ejemplar con id % no existe.', p_id_ejemplar;
    END IF;

    IF v_estado_ejemplar <> 'Disponible' THEN
        RAISE EXCEPTION 'El ejemplar % no está disponible. Estado actual: %.',
            p_id_ejemplar, v_estado_ejemplar;
    END IF;

    -- 2. Verificar que el socio existe y está solvente
    SELECT esta_solvente INTO v_solvente
    FROM socios
    WHERE id_socio = p_id_socio;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El socio con id % no existe.', p_id_socio;
    END IF;

    IF NOT v_solvente THEN
        RAISE EXCEPTION 'El socio % tiene multas pendientes y no puede realizar préstamos.',
            p_id_socio;
    END IF;

    -- 3. Verificar que el empleado existe
    IF NOT EXISTS (SELECT 1 FROM empleados WHERE id_empleado = p_id_empleado) THEN
        RAISE EXCEPTION 'El empleado con id % no existe.', p_id_empleado;
    END IF;

    -- 4. Verificar límite de 3 préstamos activos por socio
    SELECT COUNT(*) INTO v_prestamos_activos
    FROM prestamos p
    WHERE p.id_socio = p_id_socio
      AND NOT EXISTS (
          SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
      );

    IF v_prestamos_activos >= 3 THEN
        RAISE EXCEPTION 'El socio % ya tiene 3 préstamos activos. Debe devolver uno antes.',
            p_id_socio;
    END IF;

    -- 5. Registrar el préstamo
    INSERT INTO prestamos (id_ejemplar, id_socio, id_empleado, fecha_salida, fecha_limite)
    VALUES (
        p_id_ejemplar,
        p_id_socio,
        p_id_empleado,
        CURRENT_DATE,
        CURRENT_DATE + (p_dias || ' days')::INTERVAL
    );

    -- 6. Marcar el ejemplar como Prestado
    UPDATE ejemplares
    SET estado = 'Prestado'
    WHERE id_ejemplar = p_id_ejemplar;

    RAISE NOTICE 'Préstamo registrado. Ejemplar: %, Socio: %, Días: %.',
        p_id_ejemplar, p_id_socio, p_dias;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error al procesar préstamo: %', SQLERRM;
END;
$$;


-- SP 2: REGISTRAR DEVOLUCIÓN
-- Registra la devolución de un préstamo validando que exista
-- y no haya sido devuelto ya. El trigger trg_multa (creado en
-- Transacciones_y_tigger.sql) se dispara automáticamente si hay retraso.
CREATE OR REPLACE PROCEDURE sp_registrar_devolucion(
    p_id_prestamo   INT,
    p_fecha_entrega DATE DEFAULT CURRENT_DATE,
    p_observaciones TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existe_prestamo BOOLEAN;
    v_ya_devuelto     BOOLEAN;
BEGIN
    -- 1. Validar que el préstamo existe
    SELECT EXISTS (
        SELECT 1 FROM prestamos WHERE id_prestamo = p_id_prestamo
    ) INTO v_existe_prestamo;

    IF NOT v_existe_prestamo THEN
        RAISE EXCEPTION 'El préstamo con id % no existe.', p_id_prestamo;
    END IF;

    -- 2. Validar que no fue devuelto ya
    SELECT EXISTS (
        SELECT 1 FROM devoluciones WHERE id_prestamo = p_id_prestamo
    ) INTO v_ya_devuelto;

    IF v_ya_devuelto THEN
        RAISE EXCEPTION 'El préstamo % ya tiene una devolución registrada.', p_id_prestamo;
    END IF;

    -- 3. Registrar la devolución (el trigger trg_multa se ejecuta aquí automáticamente)
    INSERT INTO devoluciones (id_prestamo, fecha_entrega_real, observaciones)
    VALUES (p_id_prestamo, p_fecha_entrega, p_observaciones);

    RAISE NOTICE 'Devolución registrada exitosamente para el préstamo %.', p_id_prestamo;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error al registrar devolución: %', SQLERRM;
END;
$$;


-- SP 3: PAGAR MULTA
-- Marca una multa como pagada. Si el socio ya no tiene más multas
-- pendientes, lo restaura automáticamente como solvente.
CREATE OR REPLACE PROCEDURE sp_pagar_multa(
    p_id_multa INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_socio          INT;
    v_ya_pagada         BOOLEAN;
    v_multas_pendientes INT;
BEGIN
    -- 1. Verificar que la multa existe
    SELECT id_socio, estado_pago
    INTO v_id_socio, v_ya_pagada
    FROM multas
    WHERE id_multa = p_id_multa;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La multa con id % no existe.', p_id_multa;
    END IF;

    IF v_ya_pagada THEN
        RAISE EXCEPTION 'La multa % ya fue pagada anteriormente.', p_id_multa;
    END IF;

    -- 2. Marcar la multa como pagada
    UPDATE multas
    SET estado_pago = TRUE
    WHERE id_multa = p_id_multa;

    -- 3. Contar multas pendientes restantes del socio
    SELECT COUNT(*) INTO v_multas_pendientes
    FROM multas
    WHERE id_socio = v_id_socio
      AND estado_pago = FALSE;

    -- 4. Si ya no tiene deudas, restaurar solvencia
    IF v_multas_pendientes = 0 THEN
        UPDATE socios
        SET esta_solvente = TRUE
        WHERE id_socio = v_id_socio;

        RAISE NOTICE 'Multa % pagada. Socio % ahora está solvente.',
            p_id_multa, v_id_socio;
    ELSE
        RAISE NOTICE 'Multa % pagada. Socio % aún tiene % multa(s) pendiente(s).',
            p_id_multa, v_id_socio, v_multas_pendientes;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error al pagar multa: %', SQLERRM;
END;
$$;


-- SP 4: REGISTRAR NUEVO SOCIO
-- Inserta un socio con validación de nombre y correo único.
CREATE OR REPLACE PROCEDURE sp_registrar_socio(
    p_nombre VARCHAR(100),
    p_correo VARCHAR(100)
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Validar nombre
    IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
        RAISE EXCEPTION 'El nombre del socio no puede estar vacío.';
    END IF;

    -- 2. Validar correo
    IF p_correo IS NULL OR TRIM(p_correo) = '' THEN
        RAISE EXCEPTION 'El correo del socio no puede estar vacío.';
    END IF;

    -- 3. Verificar correo único
    IF EXISTS (SELECT 1 FROM socios WHERE correo = TRIM(p_correo)) THEN
        RAISE EXCEPTION 'El correo % ya está registrado en el sistema.', p_correo;
    END IF;

    -- 4. Insertar socio (esta_solvente = TRUE por defecto según schema)
    INSERT INTO socios (nombre, correo, esta_solvente)
    VALUES (TRIM(p_nombre), TRIM(p_correo), TRUE);

    RAISE NOTICE 'Socio "%" registrado exitosamente.', p_nombre;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error al registrar socio: %', SQLERRM;
END;
$$;


-- SP 5: CAMBIAR ESTADO DE EJEMPLAR
-- Cambia el estado de un ejemplar validando contra el CHECK
-- constraint del schema: Disponible, Prestado, Reservado,
-- Mantenimiento.
CREATE OR REPLACE PROCEDURE sp_cambiar_estado_ejemplar(
    p_id_ejemplar  INT,
    p_nuevo_estado VARCHAR(20)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual VARCHAR(20);
BEGIN
    -- 1. Verificar que el ejemplar existe
    SELECT estado INTO v_estado_actual
    FROM ejemplares
    WHERE id_ejemplar = p_id_ejemplar;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El ejemplar con id % no existe.', p_id_ejemplar;
    END IF;

    -- 2. Validar que el nuevo estado esté dentro del CHECK constraint
    IF p_nuevo_estado NOT IN ('Disponible', 'Prestado', 'Reservado', 'Mantenimiento') THEN
        RAISE EXCEPTION 'Estado inválido: %. Valores permitidos: Disponible, Prestado, Reservado, Mantenimiento.',
            p_nuevo_estado;
    END IF;

    -- 3. Verificar que no sea el mismo estado actual
    IF v_estado_actual = p_nuevo_estado THEN
        RAISE EXCEPTION 'El ejemplar % ya tiene el estado "%".',
            p_id_ejemplar, p_nuevo_estado;
    END IF;

    -- 4. Aplicar el cambio
    UPDATE ejemplares
    SET estado = p_nuevo_estado
    WHERE id_ejemplar = p_id_ejemplar;

    RAISE NOTICE 'Ejemplar % cambiado de "%" a "%".',
        p_id_ejemplar, v_estado_actual, p_nuevo_estado;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error al cambiar estado del ejemplar: %', SQLERRM;
END;
$$;



-- VISTA 1: v_libros_disponibles
-- Ejemplares disponibles con datos del libro, autores, editorial
-- y categoría.
CREATE OR REPLACE VIEW v_libros_disponibles AS
SELECT
    e.id_ejemplar,
    l.isbn,
    l.titulo,
    STRING_AGG(DISTINCT a.nombre_autor, ', ' ORDER BY a.nombre_autor) AS autores,
    ed.nombre_editorial,
    c.nombre_categoria,
    l.anio_publicacion,
    e.estado
FROM ejemplares e
JOIN libros      l  ON e.isbn          = l.isbn
JOIN editoriales ed ON l.id_editorial  = ed.id_editorial
JOIN categorias  c  ON l.id_categoria  = c.id_categoria
LEFT JOIN libro_autor la ON l.isbn     = la.isbn
LEFT JOIN autores     a  ON la.id_autor = a.id_autor
WHERE e.estado = 'Disponible'
GROUP BY
    e.id_ejemplar,
    l.isbn,
    l.titulo,
    ed.nombre_editorial,
    c.nombre_categoria,
    l.anio_publicacion,
    e.estado
ORDER BY l.titulo;



-- VISTA 2: v_socios_morosos
-- Socios con multas sin pagar o préstamos vencidos sin devolver.
CREATE OR REPLACE VIEW v_socios_morosos AS
SELECT
    s.id_socio,
    s.nombre,
    s.correo,
    s.esta_solvente,
    COALESCE(deuda.total_adeudado, 0.00) AS total_multas_pendientes,
    COALESCE(vencidos.cant_vencidos, 0)  AS prestamos_vencidos
FROM socios s
LEFT JOIN (
    SELECT id_socio, SUM(monto) AS total_adeudado
    FROM multas
    WHERE estado_pago = FALSE
    GROUP BY id_socio
) deuda ON s.id_socio = deuda.id_socio
LEFT JOIN (
    SELECT p.id_socio, COUNT(*) AS cant_vencidos
    FROM prestamos p
    WHERE p.fecha_limite < CURRENT_DATE
      AND NOT EXISTS (
          SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
      )
    GROUP BY p.id_socio
) vencidos ON s.id_socio = vencidos.id_socio
WHERE
    deuda.id_socio    IS NOT NULL
    OR vencidos.id_socio IS NOT NULL
ORDER BY total_multas_pendientes DESC;


-- VISTA 3: v_historial_prestamos
-- Historial completo de préstamos con estado calculado.
CREATE OR REPLACE VIEW v_historial_prestamos AS
SELECT
    p.id_prestamo,
    s.nombre   AS socio,
    l.titulo   AS libro,
    emp.nombre AS empleado_gestor,
    p.fecha_salida,
    p.fecha_limite,
    d.fecha_entrega_real,
    CASE
        WHEN d.id_devolucion IS NULL
             AND p.fecha_limite < CURRENT_DATE THEN 'Vencido sin devolver'
        WHEN d.id_devolucion IS NULL            THEN 'Activo'
        WHEN d.fecha_entrega_real > p.fecha_limite THEN 'Devuelto con retraso'
        ELSE                                         'Devuelto a tiempo'
    END AS estado_prestamo,
    GREATEST(
        COALESCE(d.fecha_entrega_real, CURRENT_DATE) - p.fecha_limite,
        0
    ) AS dias_retraso
FROM prestamos p
JOIN socios    s   ON p.id_socio    = s.id_socio
JOIN empleados emp ON p.id_empleado = emp.id_empleado
JOIN ejemplares e  ON p.id_ejemplar = e.id_ejemplar
JOIN libros    l   ON e.isbn        = l.isbn
LEFT JOIN devoluciones d ON p.id_prestamo = d.id_prestamo
ORDER BY p.fecha_salida DESC;


-- VISTA 4: v_estadisticas_libros
-- Estadísticas de inventario y popularidad por libro.
CREATE OR REPLACE VIEW v_estadisticas_libros AS
SELECT
    l.isbn,
    l.titulo,
    STRING_AGG(DISTINCT a.nombre_autor, ', ' ORDER BY a.nombre_autor) AS autores,
    c.nombre_categoria,
    ed.nombre_editorial,
    COUNT(DISTINCT e.id_ejemplar) AS total_ejemplares,
    COUNT(DISTINCT CASE
        WHEN e.estado = 'Disponible' THEN e.id_ejemplar
    END) AS ejemplares_disponibles,
    COUNT(DISTINCT p.id_prestamo) AS veces_prestado
FROM libros l
JOIN categorias  c  ON l.id_categoria = c.id_categoria
JOIN editoriales ed ON l.id_editorial = ed.id_editorial
LEFT JOIN libro_autor la ON l.isbn     = la.isbn
LEFT JOIN autores     a  ON la.id_autor = a.id_autor
LEFT JOIN ejemplares  e  ON l.isbn     = e.isbn
LEFT JOIN prestamos   p  ON e.id_ejemplar = p.id_ejemplar
GROUP BY
    l.isbn,
    l.titulo,
    c.nombre_categoria,
    ed.nombre_editorial
ORDER BY veces_prestado DESC;


-- VISTA 5: v_multas_pendientes_detalle
-- Detalle de multas sin pagar para cobro en caja.
CREATE OR REPLACE VIEW v_multas_pendientes_detalle AS
SELECT
    m.id_multa,
    s.id_socio,
    s.nombre  AS socio,
    s.correo,
    l.titulo  AS libro_prestado,
    p.fecha_salida,
    p.fecha_limite,
    d.fecha_entrega_real,
    GREATEST(
        COALESCE(d.fecha_entrega_real, CURRENT_DATE) - p.fecha_limite,
        0
    ) AS dias_retraso,
    m.monto,
    m.estado_pago
FROM multas m
JOIN socios    s   ON m.id_socio    = s.id_socio
JOIN prestamos p   ON m.id_prestamo = p.id_prestamo
JOIN ejemplares e  ON p.id_ejemplar = e.id_ejemplar
JOIN libros    l   ON e.isbn        = l.isbn
LEFT JOIN devoluciones d ON p.id_prestamo = d.id_prestamo
WHERE m.estado_pago = FALSE
ORDER BY m.monto DESC;


-- Tabla socios
CREATE INDEX IF NOT EXISTS idx_socios_correo    ON socios (correo);
CREATE INDEX IF NOT EXISTS idx_socios_nombre    ON socios (nombre);
CREATE INDEX IF NOT EXISTS idx_socios_solvente  ON socios (esta_solvente);

-- Tabla libros
CREATE INDEX IF NOT EXISTS idx_libros_titulo    ON libros (titulo);
CREATE INDEX IF NOT EXISTS idx_libros_editorial ON libros (id_editorial);
CREATE INDEX IF NOT EXISTS idx_libros_categoria ON libros (id_categoria);
CREATE INDEX IF NOT EXISTS idx_libros_anio      ON libros (anio_publicacion);

-- Tabla ejemplares
CREATE INDEX IF NOT EXISTS idx_ejemplares_isbn        ON ejemplares (isbn);
CREATE INDEX IF NOT EXISTS idx_ejemplares_estado      ON ejemplares (estado);
CREATE INDEX IF NOT EXISTS idx_ejemplares_isbn_estado ON ejemplares (isbn, estado);

-- Tabla prestamos
CREATE INDEX IF NOT EXISTS idx_prestamos_socio        ON prestamos (id_socio);
CREATE INDEX IF NOT EXISTS idx_prestamos_empleado     ON prestamos (id_empleado);
CREATE INDEX IF NOT EXISTS idx_prestamos_ejemplar     ON prestamos (id_ejemplar);
CREATE INDEX IF NOT EXISTS idx_prestamos_fecha_limite ON prestamos (fecha_limite);
CREATE INDEX IF NOT EXISTS idx_prestamos_socio_fecha  ON prestamos (id_socio, fecha_limite);

-- Tabla devoluciones
CREATE INDEX IF NOT EXISTS idx_devoluciones_prestamo ON devoluciones (id_prestamo);
CREATE INDEX IF NOT EXISTS idx_devoluciones_fecha    ON devoluciones (fecha_entrega_real);

-- Tabla multas
CREATE INDEX IF NOT EXISTS idx_multas_socio         ON multas (id_socio);
CREATE INDEX IF NOT EXISTS idx_multas_prestamo      ON multas (id_prestamo);
CREATE INDEX IF NOT EXISTS idx_multas_estado_pago   ON multas (estado_pago);
CREATE INDEX IF NOT EXISTS idx_multas_socio_estado  ON multas (id_socio, estado_pago);

-- Tabla libro_autor
CREATE INDEX IF NOT EXISTS idx_libro_autor_autor ON libro_autor (id_autor);
CREATE INDEX IF NOT EXISTS idx_libro_autor_isbn  ON libro_autor (isbn);

-- Verificar índices creados:
-- SELECT indexname, tablename FROM pg_indexes
-- WHERE schemaname = 'public' AND indexname LIKE 'idx_%'
-- ORDER BY tablename, indexname;


DO $$
DECLARE
    v_id_prestamo INT;
    v_ya_devuelto BOOLEAN;
BEGIN
    SELECT p.id_prestamo INTO v_id_prestamo
    FROM prestamos p
    WHERE NOT EXISTS (
        SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
    )
    ORDER BY p.id_prestamo
    LIMIT 1;

    IF v_id_prestamo IS NULL THEN
        RAISE EXCEPTION 'No hay préstamos activos para devolver.';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM devoluciones WHERE id_prestamo = v_id_prestamo
    ) INTO v_ya_devuelto;

    IF v_ya_devuelto THEN
        RAISE EXCEPTION 'El préstamo % ya fue devuelto anteriormente.', v_id_prestamo;
    END IF;

    INSERT INTO devoluciones (id_prestamo, fecha_entrega_real, observaciones)
    VALUES (v_id_prestamo, CURRENT_DATE, 'Devolución con manejo de excepción');

    RAISE NOTICE 'T1 OK: Devolución del préstamo % registrada correctamente.', v_id_prestamo;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T1 ERROR: %. Transacción revertida.', SQLERRM;
END;
$$;


-- T2: EJEMPLAR A MANTENIMIENTO CON EXCEPCIÓN
DO $$
DECLARE
    v_id_ejemplar INT;
BEGIN
    SELECT e.id_ejemplar INTO v_id_ejemplar
    FROM ejemplares e
    WHERE e.estado = 'Disponible'
      AND NOT EXISTS (
          SELECT 1 FROM prestamos p
          WHERE p.id_ejemplar = e.id_ejemplar
            AND NOT EXISTS (
                SELECT 1 FROM devoluciones d
                WHERE d.id_prestamo = p.id_prestamo
            )
      )
    ORDER BY e.id_ejemplar
    LIMIT 1;

    IF v_id_ejemplar IS NULL THEN
        RAISE EXCEPTION 'No hay ejemplares disponibles sin préstamos activos.';
    END IF;

    UPDATE ejemplares
    SET estado = 'Mantenimiento'
    WHERE id_ejemplar = v_id_ejemplar;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se pudo actualizar el ejemplar %.', v_id_ejemplar;
    END IF;

    RAISE NOTICE 'T2 OK: Ejemplar % enviado a Mantenimiento.', v_id_ejemplar;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T2 ERROR: %. Transacción revertida.', SQLERRM;
END;
$$;


-- T3: MARCAR SOCIOS SOLVENTES CON EXCEPCIÓN
DO $$
DECLARE
    v_actualizados INT;
BEGIN
    UPDATE socios
    SET esta_solvente = TRUE
    WHERE id_socio NOT IN (
        SELECT DISTINCT id_socio
        FROM multas
        WHERE estado_pago = FALSE
    )
    AND esta_solvente = FALSE;

    GET DIAGNOSTICS v_actualizados = ROW_COUNT;

    RAISE NOTICE 'T3 OK: % socio(s) marcado(s) como solventes.', v_actualizados;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T3 ERROR: %. Transacción revertida.', SQLERRM;
END;
$$;


-
-- T4: PAGAR LA MAYOR DEUDA CON EXCEPCIÓN
DO $$
DECLARE
    v_id_socio       INT;
    v_total_deuda    DECIMAL(10,2);
    v_multas_pagadas INT;
BEGIN
    SELECT id_socio, SUM(monto)
    INTO v_id_socio, v_total_deuda
    FROM multas
    WHERE estado_pago = FALSE
    GROUP BY id_socio
    ORDER BY SUM(monto) DESC
    LIMIT 1;

    IF v_id_socio IS NULL THEN
        RAISE EXCEPTION 'No hay multas pendientes de pago.';
    END IF;

    UPDATE multas
    SET estado_pago = TRUE
    WHERE id_socio = v_id_socio
      AND estado_pago = FALSE;

    GET DIAGNOSTICS v_multas_pagadas = ROW_COUNT;

    UPDATE socios
    SET esta_solvente = TRUE
    WHERE id_socio = v_id_socio;

    RAISE NOTICE 'T4 OK: Socio % pagó % multa(s) por un total de $%.',
        v_id_socio, v_multas_pagadas, v_total_deuda;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'T4 ERROR: %. Transacción revertida.', SQLERRM;
END;
$$;


-- T5: AJUSTE DE MULTAS CON SAVEPOINT Y EXCEPCIÓN
-
BEGIN;

UPDATE multas
SET monto = monto * 1.15
WHERE estado_pago = FALSE
  AND monto > 50;

SAVEPOINT sp_ajuste_inicial;

UPDATE multas
SET monto = 150.00
WHERE estado_pago = FALSE
  AND monto > 150;

COMMIT;