begin;
alter table taiyu.subordenes add column if not exists entregadas integer not null default 0 check (entregadas >= 0 and entregadas <= cantidad);
alter table taiyu.subordenes add column if not exists version integer not null default 0;

create or replace function public.taiyu_avanzar(
  codigo text, version_actual integer, siguiente text,
  aprobado boolean default false, unidades integer default 0
) returns void language plpgsql security definer set search_path = '' as $$
declare
  persona taiyu.personal := taiyu.operador();
  antes taiyu.subordenes;
  despues taiyu.subordenes;
  accion text;
begin
  select * into strict antes from taiyu.subordenes s where s.codigo = $1 for update;
  if version_actual is distinct from antes.version then
    raise exception 'La suborden cambió. Actualizá la cola antes de continuar.';
  end if;
  if antes.cantidad <= 0 then raise exception 'La línea está inactiva'; end if;
  if siguiente = 'Entrega' then
    if antes.etapa <> 'Completado' or unidades is null or unidades <= 0
       or unidades > antes.cantidad - antes.entregadas then
      raise exception 'Cantidad de entrega o etapa inválida';
    end if;
    update taiyu.subordenes s set
      entregadas = antes.entregadas + unidades,
      etapa = case when antes.entregadas + unidades = antes.cantidad then 'Entregado' else antes.etapa end,
      inicio_etapa = case when antes.entregadas + unidades = antes.cantidad then clock_timestamp() else antes.inicio_etapa end,
      version = antes.version + 1
    where s.codigo = $1 returning * into despues;
    accion := 'Entrega de ' || unidades || ' unidades';
  else
    if not (
      (antes.etapa = 'Ingreso' and siguiente = 'Aprobación') or
      (antes.etapa = 'Aprobación' and siguiente = 'Producción' and aprobado is true) or
      (antes.etapa = 'Producción' and siguiente = 'Completado')
    ) or siguiente is null then
      raise exception 'Transición inválida o aprobación pendiente';
    end if;
    update taiyu.subordenes s set etapa = siguiente,
      inicio_etapa = clock_timestamp(), version = antes.version + 1
    where s.codigo = $1 returning * into despues;
    accion := case when siguiente = 'Producción' then 'Aprobación manual del cliente' else 'Cambio de etapa' end;
  end if;
  insert into taiyu.movimientos(suborden,usuario,nombre,telefono,accion,anterior,nuevo)
  values (antes.codigo,persona.usuario,persona.nombre,persona.telefono,accion,to_jsonb(antes),to_jsonb(despues));
end;
$$;

create or replace function public.taiyu_seguimiento()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform taiyu.operador();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'suborden',s.codigo,'orden',s.orden,'cliente',c.nombre,'producto',s.descripcion,
      'cantidad',s.cantidad,'subtotal',s.subtotal,'fecha_entrega',s.fecha_entrega,
      'etapa',s.etapa,'inicio_etapa',s.inicio_etapa,'entregadas',s.entregadas,'version',s.version
    ) order by s.fecha_entrega,o.creado,s.posicion),'[]'::jsonb)
    from taiyu.subordenes s join taiyu.ordenes o on o.numero=s.orden
    join taiyu.clientes c on c.id=o.cliente where s.cantidad>0
  );
end;
$$;

create or replace function public.taiyu_historial(codigo text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform taiyu.operador();
  return (select coalesce(jsonb_agg(to_jsonb(m) order by m.fecha,m.id),'[]'::jsonb)
    from taiyu.movimientos m where m.suborden=$1);
end;
$$;
revoke all on function public.taiyu_avanzar(text,integer,text,boolean,integer),
 public.taiyu_seguimiento(), public.taiyu_historial(text) from public,anon;
grant execute on function public.taiyu_avanzar(text,integer,text,boolean,integer),
 public.taiyu_seguimiento(), public.taiyu_historial(text) to authenticated;
commit;