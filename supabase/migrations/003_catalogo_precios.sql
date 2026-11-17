begin;
alter table taiyu.productos add column if not exists precio_base numeric(14,2) check (precio_base >= 0 and precio_base <> 'NaN'::numeric);

create or replace function public.taiyu_categorias()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform taiyu.operador();
 return (with recursive rutas as (
 select c.id,c.superior,array[c.nombre] ruta from taiyu.categorias c where superior is null
 union all select c.id,c.superior,array_append(r.ruta,c.nombre) from taiyu.categorias c join rutas r on c.superior=r.id
 ) select coalesce(jsonb_agg(to_jsonb(r) order by ruta),'[]'::jsonb) from rutas r);
end; $$;

create or replace function public.taiyu_crear_categoria(nombre text, superior bigint default null)
returns bigint language plpgsql security definer set search_path='' as $$
declare resultado bigint;
begin
 perform taiyu.operador();
 if nullif(btrim(nombre),'') is null then raise exception 'Escribí el nombre de la categoría'; end if;
 perform pg_advisory_xact_lock(hashtextextended('taiyu-categoria-' || coalesce(superior::text,'raiz') || lower(btrim(nombre)),0));
 select c.id into resultado from taiyu.categorias c where lower(btrim(c.nombre))=lower(btrim($1)) and c.superior is not distinct from $2 limit 1;
 if resultado is null then
 insert into taiyu.categorias(nombre,superior) values(btrim($1),$2) returning id into resultado;
 end if;
 return resultado;
end; $$;

create or replace function public.taiyu_crear_producto(categoria bigint,nombre text,precio numeric)
returns bigint language plpgsql security definer set search_path='' as $$
declare persona taiyu.personal:=taiyu.operador(); resultado bigint; existente taiyu.productos;
begin
 if nullif(btrim(nombre),'') is null or categoria is null then raise exception 'Completá categoría y producto'; end if;
 if precio is null or precio::text in ('NaN','Infinity','-Infinity') or precio<0 or precio<>round(precio,2) then raise exception 'Precio inválido'; end if;
 if precio=0 and not persona.administrador then raise exception 'Solo el administrador puede usar precio cero'; end if;
 perform pg_advisory_xact_lock(hashtextextended('taiyu-producto-'||categoria::text||lower(btrim(nombre)),0));
 select * into existente from taiyu.productos p where p.categoria=$1 and lower(btrim(p.nombre))=lower(btrim($2)) limit 1;
 if found then
   if existente.activo and existente.precio_base=precio then return existente.id; end if;
   raise exception 'Ese producto ya existe en la categoría';
 end if;
 insert into taiyu.productos(categoria,nombre,precio_base) values($1,btrim($2),$3) returning id into resultado;
 return resultado;
end; $$;

create or replace function public.taiyu_catalogo_precios()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform taiyu.operador();
 return (select coalesce(jsonb_agg(jsonb_build_object('producto_id',c.producto_id,'producto',c.producto,'ruta_categoria',c.ruta_categoria,'precio_base',p.precio_base) order by c.ruta_categoria,c.producto),'[]'::jsonb)
 from public.taiyu_catalogo() c join taiyu.productos p on p.id=c.producto_id);
end; $$;
revoke all on function public.taiyu_categorias(),public.taiyu_crear_categoria(text,bigint),public.taiyu_crear_producto(bigint,text,numeric),public.taiyu_catalogo_precios() from public,anon;
grant execute on function public.taiyu_categorias(),public.taiyu_crear_categoria(text,bigint),public.taiyu_crear_producto(bigint,text,numeric),public.taiyu_catalogo_precios() to authenticated;
commit;