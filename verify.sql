-- Count tables
SELECT COUNT(*) AS total_tables 
FROM information_schema.tables 
WHERE table_schema = 'hsk';
-- Should return: 12

-- See all tables
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'hsk' 
ORDER BY table_name;