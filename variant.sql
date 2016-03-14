BEGIN;

CREATE SCHEMA IF NOT EXISTS variants;
SET LOCAL search_path TO variants, meta, public;


--- Add a variant to tagged union. The variant's primary key must be columns
--- of the same type in the same order as the tagged union's. (They don't need
--- to have the same names.)
CREATE FUNCTION variant(base regclass, variant regclass) RETURNS void AS $code$
DECLARE
  view_name      text;
  trigger_base   text := tablename(base)||':'||tablename(variant);
  insert_trigger text := quote_ident(trigger_base||'/i');
  update_trigger text := quote_ident(trigger_base||'/u');
  delete_trigger text := quote_ident(trigger_base||'/d');
  ns             text := quote_ident(schemaname(variant));
  selects        text[];
BEGIN
  --- Setup the foreign key linking variant to base.
  EXECUTE $$
    SET LOCAL search_path TO $$|| ns ||$$, public;

    ALTER TABLE $$|| variant ||$$ ADD FOREIGN KEY ($$||
      quote_cols(pk(variant))
    ||$$)
     REFERENCES $$|| base ||$$
                ON UPDATE CASCADE ON DELETE CASCADE
                DEFERRABLE INITIALLY DEFERRED;
    --- Ensures above constraint will validate at the end of the transaction.
    INSERT INTO $$|| base ||$$ SELECT $$||
      quote_cols(pk(variant))
    ||$$ FROM $$|| variant ||$$;

    --- Create the triggers that propagate changes to base.

    CREATE OR REPLACE FUNCTION $$|| insert_trigger ||$$()
    RETURNS trigger AS $t$
    BEGIN
      INSERT INTO $$|| base ||$$ VALUES ($$|| inserter(pk(variant)) ||$$);
      RETURN NEW;
    END
    $t$ LANGUAGE plpgsql;
    CREATE TRIGGER $$|| insert_trigger ||$$
    BEFORE INSERT ON $$|| variant ||$$ FOR EACH ROW
    EXECUTE PROCEDURE $$|| insert_trigger ||$$();

    CREATE OR REPLACE FUNCTION $$|| update_trigger ||$$()
    RETURNS trigger AS $t$
    BEGIN
      UPDATE $$|| base || setter(pk(base), pk(variant)) ||$$;
      RETURN NEW;
    END
    $t$ LANGUAGE plpgsql;
    CREATE TRIGGER $$|| update_trigger ||$$ BEFORE UPDATE OF $$||
      quote_cols(pk(variant))
    ||$$ ON $$|| variant ||$$ FOR EACH ROW
    EXECUTE PROCEDURE $$|| update_trigger ||$$();

    CREATE OR REPLACE FUNCTION $$|| delete_trigger ||$$()
    RETURNS trigger AS $t$
    BEGIN
      DELETE FROM $$|| base || deleter(pk(base), pk(variant)) ||$$;
      RETURN OLD;
    END
    $t$ LANGUAGE plpgsql;
    CREATE TRIGGER $$|| delete_trigger ||$$
    BEFORE DELETE ON $$|| variant ||$$ FOR EACH ROW
    EXECUTE PROCEDURE $$|| delete_trigger ||$$();
  $$;
--   --- Rebuild the view.
--   SELECT array_agg($$
--     SELECT $$|| quote_cols(pk.cols) ||$$,
--            tableoid::regclass,
--            row_to_json((tab))
--       FROM $$|| tab ||$$ AS tab
--   $$) INTO STRICT selects FROM fk JOIN pk USING (tab) WHERE other = base;
--   EXECUTE $$
--     SET LOCAL search_path TO $$|| ns ||$$, public;
--     CREATE VIEW $$|| view_name ||$$ ($$||
--       quote_cols(pk(base))
--     ||$$, type, data) AS$$||
--     array_to_string(selects, '   UNION');
END
$code$ LANGUAGE plpgsql SET search_path FROM CURRENT;


CREATE FUNCTION quote_cols(cols name[]) RETURNS text AS $$
  SELECT string_agg(quote_ident(col), ', ') FROM unnest(cols) AS col
$$ LANGUAGE sql IMMUTABLE STRICT;

CREATE FUNCTION inserter(cols name[])
RETURNS text AS $$
  SELECT string_agg('NEW.'||quote_ident(col), ', ') FROM unnest(cols) AS col
$$ LANGUAGE sql IMMUTABLE STRICT;

CREATE FUNCTION setter(left_cols name[], right_cols name[])
RETURNS text AS $$
  SELECT ' SET '||string_agg(ql||' = NEW.'||qr, ', ')
     ||' WHERE '||string_agg(ql||' = OLD.'||qr, ', ')
    FROM unnest(left_cols, right_cols) AS _(left_col, right_col),
         quote_ident(left_col) AS ql,
         quote_ident(right_col) AS qr
$$ LANGUAGE sql IMMUTABLE STRICT;

CREATE FUNCTION deleter(left_cols name[], right_cols name[])
RETURNS text AS $$
  SELECT ' WHERE '||string_agg(ql||' = OLD.'||qr, ', ')
    FROM unnest(left_cols, right_cols) AS _(left_col, right_col),
         quote_ident(left_col) AS ql,
         quote_ident(right_col) AS qr
$$ LANGUAGE sql IMMUTABLE STRICT;

END;