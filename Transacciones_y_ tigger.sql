
-- 1. FUNCIÓN AUXILIAR (MULTA)

CREATE OR REPLACE FUNCTION calcular_multa(
    p_fecha_limite DATE,
    p_fecha_entrega DATE
)
RETURNS DECIMAL(10,2)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN GREATEST((p_fecha_entrega - p_fecha_limite) * 5.00, 0.00);
END;
$$;


-- 2. TRIGGER (MULTA AUTOMÁTICA EN DEVOLUCIONES)

CREATE OR REPLACE FUNCTION fn_trigger_multa_devolucion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_fecha_limite DATE;
    v_id_socio INT;
    v_id_ejemplar INT;
BEGIN

    -- obtener datos del préstamo
    SELECT fecha_limite, id_socio, id_ejemplar
    INTO v_fecha_limite, v_id_socio, v_id_ejemplar
    FROM prestamos
    WHERE id_prestamo = NEW.id_prestamo;

    -- si hay retraso, crear multa
    IF NEW.fecha_entrega_real > v_fecha_limite THEN

        INSERT INTO multas (id_socio, id_prestamo, monto, estado_pago)
        VALUES (
            v_id_socio,
            NEW.id_prestamo,
            calcular_multa(v_fecha_limite, NEW.fecha_entrega_real),
            FALSE
        );

        UPDATE socios
        SET esta_solvente = FALSE
        WHERE id_socio = v_id_socio;

    END IF;

    -- liberar ejemplar (según tu BD: estado = Disponible)
    UPDATE ejemplares
    SET estado = 'Disponible'
    WHERE id_ejemplar = v_id_ejemplar;

    RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS trg_multa ON devoluciones;

CREATE TRIGGER trg_multa
AFTER INSERT ON devoluciones
FOR EACH ROW
EXECUTE FUNCTION fn_trigger_multa_devolucion();

CREATE OR REPLACE PROCEDURE procesar_prestamo(
    p_id_ejemplar INT,
    p_id_socio INT,
    p_id_empleado INT,
    p_dias INT DEFAULT 15
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- 1. validar existencia y disponibilidad del ejemplar
    IF NOT EXISTS (
        SELECT 1 FROM ejemplares WHERE id_ejemplar = p_id_ejemplar
    ) THEN
        RAISE EXCEPTION 'El ejemplar no existe.';
    END IF;

    IF (SELECT estado FROM ejemplares WHERE id_ejemplar = p_id_ejemplar) <> 'Disponible' THEN
        RAISE EXCEPTION 'El ejemplar no está disponible.';
    END IF;

    -- 2. validar socio solvente
    IF NOT (SELECT esta_solvente FROM socios WHERE id_socio = p_id_socio) THEN
        RAISE EXCEPTION 'El socio tiene multas pendientes.';
    END IF;

    -- 3. validar préstamos activos (máx 3)
    IF (
        SELECT COUNT(*)
        FROM prestamos p
        WHERE p.id_socio = p_id_socio
          AND NOT EXISTS (
              SELECT 1 FROM devoluciones d
              WHERE d.id_prestamo = p.id_prestamo
          )
    ) >= 3 THEN
        RAISE EXCEPTION 'El socio ya tiene 3 préstamos activos.';
    END IF;

    -- 4. registrar préstamo
    INSERT INTO prestamos (
        id_ejemplar,
        id_socio,
        id_empleado,
        fecha_salida,
        fecha_limite
    )
    VALUES (
        p_id_ejemplar,
        p_id_socio,
        p_id_empleado,
        CURRENT_DATE,
        CURRENT_DATE + (p_dias || ' days')::INTERVAL
    );

    -- 5. actualizar estado del ejemplar
    UPDATE ejemplares
    SET estado = 'Prestado'
    WHERE id_ejemplar = p_id_ejemplar;

END;
$$;


-- 4. TRANSACCIONES
-- T1: DEVOLUCIÓN (ACTIVA TRIGGER)
BEGIN;

INSERT INTO devoluciones (id_prestamo, fecha_entrega_real, observaciones)
SELECT id_prestamo, CURRENT_DATE, 'devolución automática'
FROM prestamos
WHERE NOT EXISTS (
    SELECT 1 FROM devoluciones d
    WHERE d.id_prestamo = prestamos.id_prestamo
)
LIMIT 1;

COMMIT;


-- T2: EJEMPLAR A MANTENIMIENTO
BEGIN;

UPDATE ejemplares
SET estado = 'Mantenimiento'
WHERE id_ejemplar = (
    SELECT e.id_ejemplar
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
    LIMIT 1
);

COMMIT;


-- T3: MARCAR SOCIOS SOLVENTES
BEGIN;

UPDATE socios
SET esta_solvente = TRUE
WHERE NOT EXISTS (
    SELECT 1 FROM multas m
    WHERE m.id_socio = socios.id_socio
      AND m.estado_pago = FALSE
);

COMMIT;


-- T4: PAGAR MAYOR DEUDA
BEGIN;

UPDATE multas
SET estado_pago = TRUE
WHERE id_socio = (
    SELECT id_socio
    FROM multas
    WHERE estado_pago = FALSE
    GROUP BY id_socio
    ORDER BY SUM(monto) DESC
    LIMIT 1
);

COMMIT;


-- T5: AJUSTE DE MULTAS
BEGIN;

UPDATE multas
SET monto = monto * 1.15
WHERE estado_pago = FALSE AND monto > 50;

SAVEPOINT ajuste_inicial;

UPDATE multas
SET monto = 150
WHERE estado_pago = FALSE AND monto > 150;

COMMIT;