-- VISTA 1: v_libros_disponibles
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