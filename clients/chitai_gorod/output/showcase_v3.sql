-- showcase_v3.sql
-- Fixes applied:
--   1. Removed FINAL → replaced with argMax CTE
--   2. Split stock + sales into separate CTEs before joining
--   3. Added pt_id IN (moscow_shops) pushdown in stock CTE

WITH

moscow_shops AS (
    SELECT pt_id AS shop_id
    FROM analytics.retail_shops_dict
    WHERE brand = 'ЧГ'
        AND city = 'Москва'
        AND date_opened <= today() - 180
        AND (date_closed IS NULL OR date_closed > today())
        AND date_transport_stop IS NULL
    LIMIT 10
),

-- Fix #1: was FINAL, replaced with argMax to avoid full-table dedup scan
shops_info AS (
    SELECT
        pt_id,
        argMax(date_opened,        _version) AS date_opened,
        argMax(pl_simple_name,     _version) AS pl_simple_name,
        argMax(power_11,           _version) AS power_11,
        argMax(partner_format_id,  _version) AS partner_format_id,
        argMax(branch_name,        _version) AS branch_name
    FROM analytics.retail_shops_info
    WHERE pt_id IN (SELECT shop_id FROM moscow_shops)
    GROUP BY pt_id
),

books_catalog AS (
    SELECT
        toInt64(book_id)            AS book_id,
        writers_last_names          AS author_last_name,
        publisher,
        publisher_series            AS series_name,
        cycle_id,
        category_2                  AS category_lvl2,
        category_2_id               AS category_lvl2_id,
        category_3                  AS category_lvl3,
        category_3_id               AS category_lvl3_id,
        category_4                  AS category_lvl4,
        category_4_id               AS category_lvl4_id,
        total_amount                AS print_run,
        page_count,
        weight,
        size,
        binding_type,
        age_restriction,
        first_publication_date      AS first_pub_date,
        last_publication_date       AS last_pub_date,
        preorder_status,
        videos_cnt,
        excerpts_cnt,
        additional_images_cnt
    FROM analytics.recsys_catalog_pim
    WHERE category_1 = 'Книги'
        AND available_for_sale = true
),

-- Fix #2: filter by shop_id BEFORE joining with receipts
stock AS (
    SELECT
        toDate(ondate)    AS stock_date,
        toInt64(goods_id) AS goods_id,
        pt_id             AS shop_id,
        sum(rem)          AS rem_qty
    FROM analytics.wh_remainder_shops
    WHERE toDate(ondate) >= today() - 31
        AND toDate(ondate) < today()
        AND goods_id != 0
        AND pt_id IN (SELECT shop_id FROM moscow_shops)
    GROUP BY stock_date, goods_id, shop_id
),

sales AS (
    SELECT
        toDate(r.sale_time)                                              AS sale_date,
        toInt64(r.goods_id)                                              AS goods_id,
        r.shop                                                           AS shop_id,
        sumIf(r.goods_quantity,    r.goods_quantity > 0)                 AS qty_sold,
        sumIf(r.goods_sale_amount, r.goods_sale_amount > 0)              AS revenue,
        countIf(r.goods_quantity < 0)                                    AS n_returns,
        abs(sumIf(r.goods_quantity, r.goods_quantity < 0))               AS qty_returned,
        sumIf(r.goods_discount_value, r.goods_discount_value > 0)        AS total_discount,
        IF(
            sumIf(r.goods_quantity, r.goods_quantity > 0) > 0,
            sumIf(r.goods_sale_amount, r.goods_sale_amount > 0)
                / sumIf(r.goods_quantity, r.goods_quantity > 0),
            NULL
        )                                                                AS avg_unit_price,
        max(toUInt8(
            notEmpty(arrayFilter(x -> (x IS NOT NULL AND x != ''), r.discount_type))
        ))                                                               AS has_any_discount
    FROM analytics.cdm_retail_receipts AS r
    WHERE r.operation_day >= today() - 30
        AND r.operation_day < today()
        AND r.shop IN (SELECT shop_id FROM moscow_shops)
        AND r.is_internet_sale = 'Оффлайн'
        AND r.is_normal = 1
        AND (r.goods_storno IS NULL OR r.goods_storno = 0)
        AND (r.is_1_rub_sale IS NULL OR r.is_1_rub_sale = 0)
        AND r.directory_type = 11
    GROUP BY sale_date, goods_id, shop_id
)

SELECT
    st.stock_date                                                        AS sale_date,
    st.shop_id,
    si.pl_simple_name                                                    AS shop_name,
    si.partner_format_id                                                 AS shop_format,
    si.power_11                                                          AS shop_power,
    si.branch_name                                                       AS branch,
    st.goods_id,
    bc.author_last_name,
    bc.publisher,
    bc.series_name,
    bc.cycle_id,
    bc.category_lvl2,
    bc.category_lvl2_id,
    bc.category_lvl3,
    bc.category_lvl3_id,
    bc.category_lvl4,
    bc.category_lvl4_id,
    bc.print_run,
    bc.page_count,
    bc.weight,
    bc.size,
    bc.binding_type,
    bc.age_restriction,
    bc.first_pub_date,
    bc.last_pub_date,
    bc.preorder_status,
    bc.videos_cnt,
    bc.excerpts_cnt,
    bc.additional_images_cnt,
    toUInt8(st.rem_qty <= 0)                                             AS is_stockout,
    st.rem_qty                                                           AS stock_rem,
    coalesce(s.qty_sold,      0)                                         AS qty_sold,
    coalesce(s.revenue,       0)                                         AS revenue,
    coalesce(s.n_returns,     0)                                         AS n_returns,
    coalesce(s.qty_returned,  0)                                         AS qty_returned,
    coalesce(s.total_discount,0)                                         AS total_discount,
    s.avg_unit_price,
    coalesce(s.has_any_discount, 0)                                      AS has_any_discount
FROM stock AS st
INNER JOIN shops_info AS si ON st.shop_id = si.pt_id
LEFT JOIN sales AS s
    ON st.stock_date = s.sale_date
    AND st.shop_id   = s.shop_id
    AND st.goods_id  = s.goods_id
LEFT JOIN books_catalog AS bc ON st.goods_id = bc.book_id
ORDER BY st.stock_date, st.shop_id, st.goods_id
