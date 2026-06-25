-- showcase_v4.sql
-- Fix: stock no longer uses IN (SELECT FROM sales) — replaced with JOIN to avoid double scan

WITH

params AS (
    SELECT
        'Москва' AS city,
        1        AS shop_limit,
        20       AS days_back
),

moscow_shops AS (
    SELECT pt_id AS shop_id
    FROM analytics.retail_shops_dict, params
    WHERE brand = 'ЧГ'
        AND city = params.city
        AND date_opened <= today() - 180
        AND (date_closed IS NULL OR date_closed > today())
        AND date_transport_stop IS NULL
    LIMIT (SELECT shop_limit FROM params)
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
    WHERE category_1 = 'Книги'
        AND available_for_sale = true
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
    FROM analytics.cdm_retail_receipts AS r, params
    WHERE r.operation_day >= today() - params.days_back
        AND r.operation_day < today()
        AND r.shop IN (SELECT shop_id FROM moscow_shops)
        AND r.is_internet_sale = 'Оффлайн'
        AND r.is_normal = 1
        AND (r.goods_storno IS NULL OR r.goods_storno = 0)
        AND (r.is_1_rub_sale IS NULL OR r.is_1_rub_sale = 0)
        AND r.directory_type = 11
    GROUP BY sale_date, goods_id, shop_id
),

-- stock фильтруется через JOIN с sales, не через IN (SELECT) — избегаем двойного скана sales
stock AS (
    SELECT
        toDate(w.ondate)    AS stock_date,
        toInt64(w.goods_id) AS goods_id,
        w.pt_id             AS shop_id,
        sum(w.rem)          AS rem_qty
    FROM analytics.wh_remainder_shops AS w, params
    INNER JOIN (
        SELECT DISTINCT goods_id, shop_id FROM sales
    ) AS s ON toInt64(w.goods_id) = s.goods_id AND w.pt_id = s.shop_id
    WHERE toDate(w.ondate) >= today() - params.days_back - 1
        AND toDate(w.ondate) < today()
    GROUP BY stock_date, goods_id, shop_id
)

SELECT
    s.sale_date,
    s.shop_id,
    si.shop_name,
    si.shop_format,
    si.shop_power,
    si.branch,
    s.goods_id,
    bc.book_name,
    bc.author_last_name,
    bc.publisher,
    bc.series_name,
    bc.cycle_id,
    bc.category_lvl2,    bc.category_lvl2_id,
    bc.category_lvl3,    bc.category_lvl3_id,
    bc.category_lvl4,    bc.category_lvl4_id,
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
    coalesce(st.rem_qty, 0)                        AS stock_rem,
    toUInt8(st.rem_qty IS NULL OR st.rem_qty <= 0) AS is_stockout,
    s.qty_sold,
    s.revenue,
    s.n_returns,
    s.qty_returned,
    s.total_discount,
    s.avg_unit_price,
    s.has_any_discount
FROM sales AS s
INNER JOIN shops_info AS si ON s.shop_id = si.pt_id
LEFT JOIN books_catalog AS bc ON s.goods_id = bc.book_id
LEFT JOIN stock AS st
    ON  st.stock_date = s.sale_date - INTERVAL 1 DAY
    AND st.shop_id    = s.shop_id
    AND st.goods_id   = s.goods_id
ORDER BY s.sale_date, s.shop_id, s.goods_id
