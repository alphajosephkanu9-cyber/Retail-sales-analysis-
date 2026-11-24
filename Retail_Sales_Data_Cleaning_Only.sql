-- RETAIL SALES ANALYSIS — DATA CLEANING ONLY
-- MySQL 8.0+
-- Creates cleaned working tables while preserving all original source tables.
-- Confirm that the sales table contains the Sale_Date column before running.

-- ====================================================================
-- 01 Data Cleaning
-- ====================================================================

-- SECTION 01: DATA CLEANING
-- Purpose: create analysis-ready copies without modifying the original tables.
-- IMPORTANT:
--   1. Raw tables (sales, customers, products, stores) remain unchanged.
--   2. Review duplicate candidates before accepting the deduplication assumption.
--   3. The supplied script uses Sale_Date elsewhere; confirm that this column exists.
--   4. This section assumes one sales line is uniquely described by the combination
--      of Transaction_ID, Sale_Date, Customer_ID, Product_ID, Store_ID,
--      Quantity, Unit_Price and Discount. If the source has a true Sales_Line_ID,
--      use that key instead and investigate repeated combinations before deletion.

USE retail_analytics;

-- 01A. Preserve an auditable list of exact duplicate candidates.
DROP TABLE IF EXISTS sales_duplicate_review;

CREATE TABLE sales_duplicate_review AS
SELECT
    Transaction_ID,
    Sale_Date,
    Customer_ID,
    Product_ID,
    Store_ID,
    Quantity,
    Unit_Price,
    Discount,
    COUNT(*) AS duplicate_count
FROM sales
GROUP BY
    Transaction_ID, Sale_Date, Customer_ID, Product_ID, Store_ID,
    Quantity, Unit_Price, Discount
HAVING COUNT(*) > 1;

-- Review these rows and their frequency before deduplication.
SELECT *
FROM sales_duplicate_review
ORDER BY duplicate_count DESC, Transaction_ID;

-- 01B. Create a cleaned sales table, retaining one copy of each exact duplicate.
-- The original sales table is not deleted from or updated.
DROP TABLE IF EXISTS sales_cleaned;

CREATE TABLE sales_cleaned AS
WITH ranked_sales AS (
    SELECT
        Transaction_ID,
        Sale_Date,
        Customer_ID,
        Product_ID,
        Store_ID,
        Quantity,
        Unit_Price,
        Discount,
        ROW_NUMBER() OVER (
            PARTITION BY
                Transaction_ID, Sale_Date, Customer_ID, Product_ID, Store_ID,
                Quantity, Unit_Price, Discount
            ORDER BY Transaction_ID
        ) AS duplicate_row_number
    FROM sales
)
SELECT
    Transaction_ID,
    Sale_Date,
    Customer_ID,
    Product_ID,
    Store_ID,
    Quantity,
    Unit_Price,
    Discount
FROM ranked_sales
WHERE duplicate_row_number = 1;

-- 01C. Isolate rows with invalid or incomplete sales measures for investigation.
-- They are not silently deleted from the raw table or the cleaned copy.
DROP TABLE IF EXISTS sales_quality_exceptions;

CREATE TABLE sales_quality_exceptions AS
SELECT
    s.*,
    CASE
        WHEN Transaction_ID IS NULL THEN 'Missing Transaction_ID'
        WHEN Sale_Date IS NULL THEN 'Missing Sale_Date'
        WHEN Quantity IS NULL THEN 'Missing Quantity'
        WHEN Quantity <= 0 THEN 'Quantity is zero or negative'
        WHEN Unit_Price IS NULL THEN 'Missing Unit_Price'
        WHEN Unit_Price <= 0 THEN 'Unit_Price is zero or negative'
        WHEN Discount IS NULL THEN 'Missing Discount'
        WHEN Discount < 0 OR Discount > 1 THEN 'Discount outside 0-1 range'
        ELSE 'Other review required'
    END AS quality_issue
FROM sales s
WHERE Transaction_ID IS NULL
   OR Sale_Date IS NULL
   OR Quantity IS NULL OR Quantity <= 0
   OR Unit_Price IS NULL OR Unit_Price <= 0
   OR Discount IS NULL OR Discount < 0 OR Discount > 1;

-- 01D. Create an analysis-ready subset for measures that require valid sales values.
-- Rows with missing dimension keys are retained here so revenue is not discarded;
-- resolve unmatched Customer_ID/Product_ID/Store_ID separately before dimension joins.
DROP TABLE IF EXISTS sales_analysis_ready;

CREATE TABLE sales_analysis_ready AS
SELECT *
FROM sales_cleaned
WHERE Transaction_ID IS NOT NULL
  AND Sale_Date IS NOT NULL
  AND Quantity > 0
  AND Unit_Price > 0
  AND Discount BETWEEN 0 AND 1;

-- 01E. Standardize known descriptive text fields in separate cleaned dimensions.
-- TRIM removes leading/trailing spaces; blank strings become NULL.
DROP TABLE IF EXISTS products_cleaned;

CREATE TABLE products_cleaned AS
SELECT
    Product_ID,
    Product_Name,
    NULLIF(TRIM(Category), '') AS Category,
    Unit_Cost
FROM products;

DROP TABLE IF EXISTS customers_cleaned;

CREATE TABLE customers_cleaned AS
SELECT
    Customer_ID,
    Customer_Name,
    NULLIF(TRIM(City), '') AS City
FROM customers;

-- 01F. Validate the cleaning results.
SELECT 'Raw sales' AS table_name, COUNT(*) AS row_count FROM sales
UNION ALL
SELECT 'Sales after exact-duplicate removal', COUNT(*) FROM sales_cleaned
UNION ALL
SELECT 'Sales analysis-ready', COUNT(*) FROM sales_analysis_ready
UNION ALL
SELECT 'Sales quality exceptions', COUNT(*) FROM sales_quality_exceptions;

-- Remaining exact duplicate combinations should return no rows.
SELECT
    Transaction_ID, Sale_Date, Customer_ID, Product_ID, Store_ID,
    Quantity, Unit_Price, Discount, COUNT(*) AS row_count
FROM sales_cleaned
GROUP BY
    Transaction_ID, Sale_Date, Customer_ID, Product_ID, Store_ID,
    Quantity, Unit_Price, Discount
HAVING COUNT(*) > 1;

-- Confirm no invalid measure/date rows remain in the analysis-ready table.
SELECT
    SUM(Transaction_ID IS NULL) AS missing_transaction_id,
    SUM(Sale_Date IS NULL) AS missing_sale_date,
    SUM(Quantity IS NULL OR Quantity <= 0) AS invalid_quantity,
    SUM(Unit_Price IS NULL OR Unit_Price <= 0) AS invalid_unit_price,
    SUM(Discount IS NULL OR Discount < 0 OR Discount > 1) AS invalid_discount
FROM sales_analysis_ready;

-- Recheck unmatched dimension keys on the cleaned analysis-ready sales.
SELECT 'customer' AS key_type, COUNT(*) AS unmatched_rows
FROM sales_analysis_ready s
LEFT JOIN customers_cleaned c ON s.Customer_ID = c.Customer_ID
WHERE s.Customer_ID IS NOT NULL AND c.Customer_ID IS NULL
UNION ALL
SELECT 'product', COUNT(*)
FROM sales_analysis_ready s
LEFT JOIN products_cleaned p ON s.Product_ID = p.Product_ID
WHERE s.Product_ID IS NOT NULL AND p.Product_ID IS NULL
UNION ALL
SELECT 'store', COUNT(*)
FROM sales_analysis_ready s
LEFT JOIN stores st ON s.Store_ID = st.Store_ID
WHERE s.Store_ID IS NOT NULL AND st.Store_ID IS NULL;

-- From this point onward, analytical sections should use:
--   sales_analysis_ready instead of sales
--   products_cleaned instead of products (where descriptive text is needed)
--   customers_cleaned instead of customers (where descriptive text is needed)
-- The original raw tables remain available for comparison and audit.
