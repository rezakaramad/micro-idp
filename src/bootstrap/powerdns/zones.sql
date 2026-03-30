-- Zones
INSERT INTO domains (name, type)
VALUES 
  ('rezakara.demo', 'NATIVE'),
  ('mgmt.rezakara.demo', 'NATIVE'),
  ('wl.rezakara.demo', 'NATIVE')
ON CONFLICT (name) DO NOTHING;

-- SOA
INSERT INTO records (domain_id, name, type, content, ttl)
SELECT id, name, 'SOA',
       'ns1.rezakara.demo admin.rezakara.demo 1 10800 3600 604800 3600',
       3600
FROM domains
WHERE name IN ('rezakara.demo', 'mgmt.rezakara.demo', 'wl.rezakara.demo')
ON CONFLICT DO NOTHING;

-- NS
INSERT INTO records (domain_id, name, type, content, ttl)
SELECT id, name, 'NS', 'ns1.rezakara.demo', 3600
FROM domains
WHERE name IN ('rezakara.demo', 'mgmt.rezakara.demo', 'wl.rezakara.demo')
ON CONFLICT DO NOTHING;