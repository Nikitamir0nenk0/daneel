-- showcase_v5.sql
-- Fix: убраны алиасы таблиц (s., si., bc., st.) в финальном SELECT
-- ClickHouse 25.1 не резолвит алиасы CTE через точку в финальном SELECT

WITH

moscow_shops AS (
    SELECT pt_id AS shop_id
    FROM analytics.retail_shops_dict
    WHERE brand = 'ЧГ'
        AND city = 'Москва'
        AND date_opened <= today() - 180
        AND (date_closed IS NULL OR date_closed > today())
        AND date_transport_stop IS NULL
    LIMIT 1
),

shops_info AS (
    SELECT
        pt_id,
        argMax(pl_simple_name,    date_update) AS shop_name,
        argMax(power_11,          date_update) AS shop_power,
        argMax(partner_format_id, date_update) AS shop_format,
        argMax(branch_name,       date_update) AS branch
    FROM analytics.retail_shops_info
    WHERE pt_id IN (SELECT shop_id FROM moscow_shops)
    GROUP BY pt_id
),

sales AS (
    SELECT
        toDate(r.sale_time)                                             AS sale_date,
        toInt64(r.goods_id)                                             AS goods_id,
        r.shop                                                          AS shop_id,
        sumIf(r.goods_quantity,       r.goods_quantity > 0)            AS qty_sold,
        sumIf(r.goods_sale_amount,    r.goods_sale_amount > 0)         AS revenue,
        countIf(r.goods_quantity < 0)                                  AS n_returns,
        abs(sumIf(r.goods_quantity,   r.goods_quantity < 0))           AS qty_returned,
        sumIf(r.goods_discount_value, r.goods_discount_value > 0)      AS total_discount,
        IF(
            sumIf(r.goods_quantity, r.goods_quantity > 0) > 0,
            sumIf(r.goods_sale_amount, r.goods_sale_amount > 0)
                / sumIf(r.goods_quantity, r.goods_quantity > 0),
            NULL
        )                                                               AS avg_unit_price,
        max(toUInt8(r.goods_discount_value > 0))                       AS has_any_discount
    FROM analytics.cdm_retail_receipts AS r
    WHERE r.operation_day >= today() - 20
        AND r.operation_day < today()
        AND r.shop IN (SELECT shop_id FROM moscow_shops)
        AND r.is_internet_sale = 'Оффлайн'
        AND r.is_normal = 1
        AND (r.goods_storno IS NULL OR r.goods_storno = 0)
        AND (r.is_1_rub_sale IS NULL OR r.is_1_rub_sale = 0)
        AND r.directory_type = 11
    GROUP BY sale_date, goods_id, shop_id
),

stock AS (
    SELECT
        toDate(w.ondate)    AS stock_date,
        toInt64(w.goods_id) AS goods_id,
        w.pt_id             AS shop_id,
        sum(w.rem)          AS rem_qty
    FROM analytics.wh_remainder_shops AS w
    INNER JOIN (
        SELECT DISTINCT goods_id, shop_id FROM sales
    ) AS s ON toInt64(w.goods_id) = s.goods_id AND w.pt_id = s.shop_id
    WHERE toDate(w.ondate) >= today() - 21
        AND toDate(w.ondate) < today()
    GROUP BY stock_date, goods_id, shop_id
),

books_catalog AS (
    SELECT
        toInt64(book_id)          AS book_id,
        name                      AS book_name,
        writers_last_names        AS author_last_name,
        publisher,
        publisher_series          AS series_name,
        cycle_id,
        category_2                AS category_lvl2,
        category_2_id             AS category_lvl2_id,
        category_3                AS category_lvl3,
        category_3_id             AS category_lvl3_id,
        category_4                AS category_lvl4,
        category_4_id             AS category_lvl4_id,
        total_amount              AS print_run,
        page_count,
        weight,
        size,
        binding_type,
        age_restriction,
        first_publication_date    AS first_pub_date,
        last_publication_date     AS last_pub_date,
        preorder_status,
        videos_cnt,
        excerpts_cnt,
        additional_images_cnt
    FROM analytics.recsys_catalog_pim
    WHERE toInt64(book_id) IN (SELECT goods_id FROM sales)
),

-- Финальная сборка без алиасов таблиц — ClickHouse 25.1 CTE scope workaround
final AS (
    SELECT
        sale_date,
        sales.shop_id                                          AS shop_id,
        shop_name,
        shop_format,
        shop_power,
        branch,
        sales.goods_id                                         AS goods_id,
        book_name,
        author_last_name,
        publisher,
        series_name,
        cycle_id,
        category_lvl2,    category_lvl2_id,
        category_lvl3,    category_lvl3_id,
        category_lvl4,    category_lvl4_id,
        print_run,
        page_count,
        weight,
        size,
        binding_type,
        age_restriction,
        first_pub_date,
        last_pub_date,
        preorder_status,
        videos_cnt,
        excerpts_cnt,
        additional_images_cnt,
        coalesce(rem_qty, 0)                        AS stock_rem,
        toUInt8(rem_qty IS NULL OR rem_qty <= 0)    AS is_stockout,
        qty_sold,
        revenue,
        n_returns,
        qty_returned,
        total_discount,
        avg_unit_price,
        has_any_discount
    FROM sales
    INNER JOIN shops_info    ON sales.shop_id  = shops_info.pt_id
    LEFT JOIN books_catalog  ON sales.goods_id = books_catalog.book_id
    LEFT JOIN stock
        ON  stock.stock_date = sales.sale_date - INTERVAL 1 DAY
        AND stock.shop_id    = sales.shop_id
        AND stock.goods_id   = sales.goods_id
)

SELECT *
FROM final
ORDER BY sale_date, shop_id, goods_id
