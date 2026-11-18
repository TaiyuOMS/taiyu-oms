begin;
alter table taiyu.subordenes alter column etapa set default 'Aprobación';

-- En pedidos nuevos, cada línea empieza pendiente de aprobación.
create or replace function taiyu.iniciar_en_aprobacion()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.etapa := 'Aprobación';
  return new;
end;
$$;
drop trigger if exists iniciar_en_aprobacion on taiyu.subordenes;
create trigger iniciar_en_aprobacion before insert on taiyu.subordenes
for each row execute function taiyu.iniciar_en_aprobacion();

-- Conserva el tiempo de espera de los pedidos ya ingresados y su historial.
do $$
declare antes taiyu.subordenes; despues taiyu.subordenes;
begin
  for antes in select * from taiyu.subordenes where etapa='Ingreso' for update loop
    update taiyu.subordenes set etapa='Aprobación',version=version+1
    where codigo=antes.codigo returning * into despues;
    insert into taiyu.movimientos(suborden,usuario,nombre,telefono,accion,anterior,nuevo,motivo)
    select antes.codigo,p.usuario,p.nombre,p.telefono,'Migración a Aprobación',
      to_jsonb(antes),to_jsonb(despues),'Se elimina la etapa Ingreso; se conserva el inicio de espera.'
    from taiyu.ordenes o join taiyu.personal p on p.usuario=o.creado_por
    where o.numero=antes.orden;
  end loop;
end $$;

create or replace function public.taiyu_seguimiento_v2()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform taiyu.operador();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'suborden',s.codigo,'orden',s.orden,'cliente',c.nombre,'producto',s.descripcion,
      'categoria',coalesce(cat.nombre,'Sin categoría'),
      'cantidad',s.cantidad,'fecha_entrega',s.fecha_entrega,
      'etapa',s.etapa,'inicio_etapa',s.inicio_etapa,'entregadas',s.entregadas,'version',s.version,
      'prioridad',coalesce(o.contenido_original->'prioridad'='true'::jsonb,false)
    ) order by coalesce(o.contenido_original->'prioridad'='true'::jsonb,false) desc,
      s.fecha_entrega,o.creado,s.posicion),'[]'::jsonb)
    from taiyu.subordenes s join taiyu.ordenes o on o.numero=s.orden
    join taiyu.clientes c on c.id=o.cliente
    left join taiyu.productos p on p.id=s.producto
    left join taiyu.categorias cat on cat.id=p.categoria
    where s.cantidad>0
  );
end $$;

create or replace function public.taiyu_retroceder(codigo text,version_actual integer,motivo text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  persona taiyu.personal := taiyu.operador();
  antes taiyu.subordenes; despues taiyu.subordenes;
  destino text; entregadas_previas integer;
begin
  if nullif(btrim(motivo),'') is null then raise exception 'Indicá el motivo de la devolución'; end if;
  select * into strict antes from taiyu.subordenes s where s.codigo=$1 for update;
  if version_actual is distinct from antes.version then
    raise exception 'La suborden cambió. Actualizá la cola antes de continuar.';
  end if;
  destino := case antes.etapa when 'Producción' then 'Aprobación'
    when 'Completado' then 'Producción' when 'Entregado' then 'Completado' end;
  if destino is null or antes.cantidad<=0 then raise exception 'Esta tarjeta no puede retroceder'; end if;
  entregadas_previas := antes.entregadas;
  if antes.etapa='Entregado' then
    select (m.anterior->>'entregadas')::integer into entregadas_previas
    from taiyu.movimientos m where m.suborden=antes.codigo
      and m.nuevo->>'etapa'='Entregado' and m.anterior->>'etapa'='Completado'
      and (m.nuevo->>'version')::integer=antes.version
    order by m.id desc limit 1;
    if entregadas_previas is null or entregadas_previas<0 or entregadas_previas>=antes.cantidad then
      raise exception 'No se pudo identificar la última entrega para anularla.';
    end if;
  end if;
  update taiyu.subordenes s set etapa=destino,entregadas=entregadas_previas,
    inicio_etapa=clock_timestamp(),version=antes.version+1
    where s.codigo=$1 returning * into despues;
  insert into taiyu.movimientos(suborden,usuario,nombre,telefono,accion,anterior,nuevo,motivo)
  values(antes.codigo,persona.usuario,persona.nombre,persona.telefono,
    'Regreso a '||destino,to_jsonb(antes),to_jsonb(despues),btrim(motivo));
end $$;
revoke all on function taiyu.iniciar_en_aprobacion() from public,anon,authenticated;
revoke all on function public.taiyu_seguimiento_v2(),public.taiyu_retroceder(text,integer,text) from public,anon;
grant execute on function public.taiyu_seguimiento_v2(),public.taiyu_retroceder(text,integer,text) to authenticated;
notify pgrst,'reload schema';
commit;
