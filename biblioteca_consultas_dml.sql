-- BIBLIOTECA - CONSULTAS, DELETE Y UPDATE
-- Ejecutar DESPUÉS de biblioteca_schema_datos.sql

-- PARTE 1: CONSULTAS SELECT 

-- 1. Listar todos los libros publicados después del año 2000
SELECT titulo, anio_publicacion
FROM libros
WHERE anio_publicacion > 2000
ORDER BY anio_publicacion;

-- 2. Listar los socios que NO están solventes
SELECT nombre, correo
FROM socios
WHERE esta_solvente = FALSE;

-- 3. Listar ejemplares disponibles
SELECT id_ejemplar, isbn, estado
FROM ejemplares
WHERE estado = 'Disponible';

-- 4. Listar empleados que trabajan como "Encargado"
SELECT nombre, cargo
FROM empleados
WHERE cargo = 'Encargado';

-- 5. Contar cuántos libros hay en total
SELECT COUNT(*) AS total_libros
FROM libros;


-- 6. Mostrar título del libro junto con su editorial
SELECT l.titulo, e.nombre_editorial
FROM libros l
JOIN editoriales e ON l.id_editorial = e.id_editorial
ORDER BY l.titulo;

-- 7. Mostrar título del libro junto con su categoría
SELECT l.titulo, c.nombre_categoria
FROM libros l
JOIN categorias c ON l.id_categoria = c.id_categoria;

-- 8. Contar cuántos libros hay por categoría
SELECT c.nombre_categoria, COUNT(l.isbn) AS total_libros
FROM categorias c
LEFT JOIN libros l ON c.id_categoria = l.id_categoria
GROUP BY c.nombre_categoria
ORDER BY total_libros DESC;

-- 9. Promedio del monto de las multas
SELECT ROUND(AVG(monto), 2) AS promedio_multa
FROM multas;

-- 10. Editorial con más libros publicados
SELECT e.nombre_editorial, COUNT(l.isbn) AS total
FROM editoriales e
JOIN libros l ON e.id_editorial = l.id_editorial
GROUP BY e.nombre_editorial
ORDER BY total DESC
LIMIT 1;


-- 11. Listar nombre del socio y cantidad de préstamos que ha hecho
SELECT s.nombre, COUNT(p.id_prestamo) AS total_prestamos
FROM socios s
JOIN prestamos p ON s.id_socio = p.id_socio
GROUP BY s.nombre
ORDER BY total_prestamos DESC;

-- 12. Socios con más de 3 préstamos
SELECT s.nombre, COUNT(p.id_prestamo) AS total_prestamos
FROM socios s
JOIN prestamos p ON s.id_socio = p.id_socio
GROUP BY s.nombre
HAVING COUNT(p.id_prestamo) > 3
ORDER BY total_prestamos DESC;

-- 13. Listar autor, título del libro y nacionalidad del autor (3 tablas)
SELECT a.nombre_autor, a.nacionalidad, l.titulo
FROM autores a
JOIN libro_autor la ON a.id_autor = la.id_autor
JOIN libros l ON la.isbn = l.isbn
ORDER BY a.nombre_autor;

-- 14. Total de multas (suma de monto) por socio, solo socios con multas
SELECT s.nombre, SUM(m.monto) AS total_adeudado
FROM socios s
JOIN multas m ON s.id_socio = m.id_socio
GROUP BY s.nombre
ORDER BY total_adeudado DESC;

-- 15. Empleados que han gestionado más de 5 préstamos
SELECT emp.nombre, COUNT(p.id_prestamo) AS prestamos_gestionados
FROM empleados emp
JOIN prestamos p ON emp.id_empleado = p.id_empleado
GROUP BY emp.nombre
HAVING COUNT(p.id_prestamo) > 5
ORDER BY prestamos_gestionados DESC;


-- Subconsultas

-- 16. Libros que nunca se han prestado (subconsulta NOT IN)
SELECT l.titulo
FROM libros l
WHERE l.isbn NOT IN (
    SELECT e.isbn
    FROM ejemplares e
    JOIN prestamos p ON e.id_ejemplar = p.id_ejemplar
);

-- 17. Socios cuyo total de multas es mayor al promedio general de multas por socio
SELECT s.nombre, SUM(m.monto) AS total_multas
FROM socios s
JOIN multas m ON s.id_socio = m.id_socio
GROUP BY s.nombre
HAVING SUM(m.monto) > (
    SELECT AVG(monto_total)
    FROM (
        SELECT SUM(monto) AS monto_total
        FROM multas
        GROUP BY id_socio
    ) sub
);

-- 18. Libro(s) con más ejemplares registrados (subconsulta con MAX)
SELECT l.titulo, conteo.total_ejemplares
FROM libros l
JOIN (
    SELECT isbn, COUNT(*) AS total_ejemplares
    FROM ejemplares
    GROUP BY isbn
) conteo ON l.isbn = conteo.isbn
WHERE conteo.total_ejemplares = (
    SELECT MAX(cnt) FROM (
        SELECT COUNT(*) AS cnt FROM ejemplares GROUP BY isbn
    ) maxsub
);

-- 19. Autores que han escrito más libros que el promedio de libros por autor
SELECT a.nombre_autor, COUNT(la.isbn) AS total_libros
FROM autores a
JOIN libro_autor la ON a.id_autor = la.id_autor
GROUP BY a.nombre_autor
HAVING COUNT(la.isbn) > (
    SELECT AVG(cnt) FROM (
        SELECT COUNT(*) AS cnt FROM libro_autor GROUP BY id_autor
    ) avg_sub
);

-- 20. Socios que tienen préstamos pero ninguna devolución registrada
SELECT s.nombre
FROM socios s
WHERE s.id_socio IN (
    SELECT p.id_socio FROM prestamos p
)
AND NOT EXISTS (
    SELECT 1
    FROM prestamos p2
    JOIN devoluciones d ON p2.id_prestamo = d.id_prestamo
    WHERE p2.id_socio = s.id_socio
);


-- Avanzado (CTEs, ventanas, COALESCE)

-- 21. Ranking de socios por monto total de multas usando función de ventana
SELECT
    s.nombre,
    SUM(m.monto) AS total_multas,
    RANK() OVER (ORDER BY SUM(m.monto) DESC) AS posicion
FROM socios s
JOIN multas m ON s.id_socio = m.id_socio
GROUP BY s.nombre;

-- 22. CTE: top 5 libros más prestados con su autor principal
WITH conteo_prestamos AS (
    SELECT e.isbn, COUNT(p.id_prestamo) AS veces_prestado
    FROM ejemplares e
    JOIN prestamos p ON e.id_ejemplar = p.id_ejemplar
    GROUP BY e.isbn
)
SELECT l.titulo, a.nombre_autor, cp.veces_prestado
FROM conteo_prestamos cp
JOIN libros l ON cp.isbn = l.isbn
JOIN libro_autor la ON l.isbn = la.isbn
JOIN autores a ON la.id_autor = a.id_autor
ORDER BY cp.veces_prestado DESC
LIMIT 5;

-- 23. Días de retraso promedio por empleado que gestionó el préstamo
-- (COALESCE para préstamos sin devolución registrada)
SELECT
    emp.nombre,
    ROUND(AVG(COALESCE(d.fecha_entrega_real, CURRENT_DATE) - p.fecha_limite), 2) AS retraso_promedio_dias
FROM empleados emp
JOIN prestamos p ON emp.id_empleado = p.id_empleado
LEFT JOIN devoluciones d ON p.id_prestamo = d.id_prestamo
GROUP BY emp.nombre
ORDER BY retraso_promedio_dias DESC;

-- 24. Porcentaje de ejemplares por estado, respecto al total general
SELECT
    estado,
    COUNT(*) AS cantidad,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS porcentaje
FROM ejemplares
GROUP BY estado
ORDER BY cantidad DESC;

-- 25. Socios morosos: tienen multas sin pagar Y préstamos vencidos sin devolver
-- (subconsulta correlacionada doble + EXISTS)
SELECT DISTINCT s.nombre, s.correo
FROM socios s
WHERE EXISTS (
    SELECT 1 FROM multas m
    WHERE m.id_socio = s.id_socio AND m.estado_pago = FALSE
)
AND EXISTS (
    SELECT 1 FROM prestamos p
    WHERE p.id_socio = s.id_socio
    AND p.fecha_limite < CURRENT_DATE
    AND NOT EXISTS (
        SELECT 1 FROM devoluciones d WHERE d.id_prestamo = p.id_prestamo
    )
);


-- PARTE 2: DELETE (progresión de dificultad)

-- 1. DELETE simple: borrar un autor específico por ID
DELETE FROM autores
WHERE id_autor = 69;

-- 2. DELETE con subconsulta NOT IN: eliminar ejemplares en mantenimiento
-- que nunca se han prestado
DELETE FROM ejemplares
WHERE estado = 'Mantenimiento'
  AND id_ejemplar NOT IN (SELECT id_ejemplar FROM prestamos);

-- 3. DELETE con condición simple: borrar multas ya pagadas y de bajo monto
DELETE FROM multas
WHERE estado_pago = TRUE
  AND monto < 10;

-- 4. DELETE con subconsulta correlacionada (NOT EXISTS): eliminar libros
-- que no tienen ningún ejemplar registrado
DELETE FROM libros
WHERE NOT EXISTS (
    SELECT 1 FROM ejemplares e WHERE e.isbn = libros.isbn
);

-- 5. DELETE en cascada controlada: eliminar un socio insolvente
-- sin préstamos activos (la condición NOT EXISTS evita violar la FK)
DELETE FROM socios
WHERE id_socio = 6
  AND esta_solvente = FALSE
  AND NOT EXISTS (
      SELECT 1 FROM prestamos p WHERE p.id_socio = socios.id_socio
  );


-- UPDATE

-- 1. UPDATE simple: marcar a un socio como solvente
UPDATE socios
SET esta_solvente = TRUE
WHERE id_socio = 3;

-- 2. UPDATE masivo: marcar todos los ejemplares "Mantenimiento" como "Disponible"
-- (simula que terminó el mantenimiento)
UPDATE ejemplares
SET estado = 'Disponible'
WHERE estado = 'Mantenimiento';

-- 3. UPDATE con CASE: requiere agregar antes la columna de severidad
-- ALTER TABLE multas ADD COLUMN severidad VARCHAR(20);
UPDATE multas
SET severidad = CASE
    WHEN monto < 20 THEN 'Leve'
    WHEN monto BETWEEN 20 AND 60 THEN 'Moderada'
    ELSE 'Grave'
END;

-- 4. UPDATE con subconsulta: marcar esta_solvente = FALSE
-- a todo socio con al menos una multa sin pagar
UPDATE socios
SET esta_solvente = FALSE
WHERE id_socio IN (
    SELECT id_socio FROM multas WHERE estado_pago = FALSE
);

-- 5. UPDATE con subconsulta correlacionada y agregación: aumentar 10%
-- el monto de la multa a socios con más de 2 multas sin pagar
UPDATE multas
SET monto = monto * 1.10
WHERE id_socio IN (
    SELECT id_socio
    FROM multas
    WHERE estado_pago = FALSE
    GROUP BY id_socio
    HAVING COUNT(*) > 2
)
AND estado_pago = FALSE;
