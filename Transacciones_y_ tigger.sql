
-- función auxiliar 

create or replace function calcular_multa(
    p_fecha_limite date,
    p_fecha_entrega date
)
returns decimal(10,2)
language plpgsql
as $$
declare
    dias_retraso int;
begin
    dias_retraso := p_fecha_entrega - p_fecha_limite;
    if dias_retraso <= 0 then
        return 0.00;
    end if;
    return dias_retraso * 5.00;
end;
$$;


-- trigger 
-- al registrar una devolución, si hay retraso inserta la multa

create or replace function fn_trigger_calcular_multa_por_devolucion()
returns trigger
language plpgsql
as $$
declare
    v_fecha_limite date;
    v_id_socio     int;
    v_monto_multa  decimal(10,2);
begin
    select p.fecha_limite, p.id_socio
    into v_fecha_limite, v_id_socio
    from prestamos p
    where p.id_prestamo = new.id_prestamo;

    v_monto_multa := calcular_multa(v_fecha_limite, new.fecha_entrega_real);

    if v_monto_multa > 0 then
        insert into multas (id_socio, id_prestamo, monto, estado_pago)
        values (v_id_socio, new.id_prestamo, v_monto_multa, false);

        update socios set esta_solvente = false where id_socio = v_id_socio;
    end if;

    update ejemplares
    set estado = 'disponible'
    where id_ejemplar = (
        select id_ejemplar from prestamos where id_prestamo = new.id_prestamo
    );

    return new;
end;
$$;

drop trigger if exists trg_calcular_multa_devolucion on devoluciones;
create trigger trg_calcular_multa_devolucion
after insert on devoluciones
for each row
execute function fn_trigger_calcular_multa_por_devolucion();



-- procedimiento 
-- procesar préstamo: verifica disponibilidad, solvencia y límite


create or replace procedure procesar_prestamo(
    p_id_ejemplar int,
    p_id_socio    int,
    p_id_empleado int,
    p_dias        int default 15
)
language plpgsql
as $$
declare
    v_estado            varchar;
    v_solvente          boolean;
    v_prestamos_activos int;
begin
    -- 1. verificar disponibilidad del ejemplar
    select estado into v_estado
    from ejemplares
    where id_ejemplar = p_id_ejemplar;

    if not found then
        raise exception 'el ejemplar % no existe.', p_id_ejemplar;
    end if;

    if v_estado <> 'disponible' then
        raise exception 'el ejemplar % no está disponible.', p_id_ejemplar;
    end if;

    -- 2. verificar solvencia del socio
    select esta_solvente into v_solvente
    from socios where id_socio = p_id_socio;

    if not v_solvente then
        raise exception 'el socio % tiene multas pendientes.', p_id_socio;
    end if;

    -- 3. verificar límite de 3 préstamos activos
    select count(*) into v_prestamos_activos
    from prestamos p
    where p.id_socio = p_id_socio
      and not exists (
          select 1 from devoluciones d where d.id_prestamo = p.id_prestamo
      );

    if v_prestamos_activos >= 3 then
        raise exception 'el socio % ya tiene 3 préstamos activos.', p_id_socio;
    end if;

    -- 4. registrar el préstamo
    insert into prestamos (id_ejemplar, id_socio, id_empleado, fecha_salida, fecha_limite)
    values (p_id_ejemplar, p_id_socio, p_id_empleado,
            current_date, current_date + (p_dias || ' days')::interval);

    -- 5. cambiar estado del ejemplar
    update ejemplares set estado = 'prestado' where id_ejemplar = p_id_ejemplar;

    raise notice 'préstamo registrado exitosamente para socio %.', p_id_socio;
end;
$$;



-- transacciones

-- t1. registrar una devolución (el trigger calcula la multa solo)
begin;
    insert into devoluciones (id_prestamo, fecha_entrega_real, observaciones)
    select id_prestamo, current_date, 'devolución en transacción'
    from prestamos
    where not exists (
        select 1 from devoluciones d where d.id_prestamo = prestamos.id_prestamo
    )
    order by id_prestamo
    limit 1;
commit;


-- t2. pasar ejemplar a mantenimiento si no tiene préstamo activo
begin;
    update ejemplares
    set estado = 'mantenimiento'
    where id_ejemplar = (
        select e.id_ejemplar
        from ejemplares e
        where e.estado = 'disponible'
          and not exists (
              select 1 from prestamos p
              where p.id_ejemplar = e.id_ejemplar
                and not exists (
                    select 1 from devoluciones d where d.id_prestamo = p.id_prestamo
                )
          )
        order by e.id_ejemplar
        limit 1
    );
commit;


-- t3. marcar solventes a socios sin multas pendientes
begin;
    update socios
    set esta_solvente = true
    where esta_solvente = false
      and not exists (
          select 1 from multas m
          where m.id_socio = socios.id_socio and m.estado_pago = false
      );
commit;


-- t4. pagar todas las multas del socio con mayor deuda
begin;
    update multas
    set estado_pago = true
    where id_socio = (
        select id_socio
        from multas
        where estado_pago = false
        group by id_socio
        order by sum(monto) desc
        limit 1
    )
    and estado_pago = false;
commit;


-- t5. aumento de multas con savepoint
begin;
    update multas
    set monto = monto * 1.15
    where estado_pago = false and monto > 50.00;

    savepoint ajuste_inicial;

    update multas
    set monto = 150.00
    where monto > 150.00 and estado_pago = false;

commit;




