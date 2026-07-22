import datetime
import logging

from airflow.exceptions import AirflowFailException

from dags.scripts.lib.connections import ch_s53
from dags.scripts.ml_team.ml_pipeline.showcase.book_demand_showcase_core_sql import (
    CLICKHOUSE_CONN_ID,
    TABLE_NAME,
    build_insert_sql_window,
)

logger = logging.getLogger(__name__)


def get_clickhouse_client():
    return ch_s53(conn_id=CLICKHOUSE_CONN_ID)


def run_window_load(window_start: datetime.date, window_end: datetime.date) -> None:
    ws = window_start.isoformat()
    we = window_end.isoformat()

    client = get_clickhouse_client()

    # 1. Pre-check
    pre_cnt = client.execute(
        f"SELECT count(*) FROM {TABLE_NAME} "
        f"WHERE day >= toDate('{ws}') AND day <= toDate('{we}')"
    )[0][0]
    logger.info("Строк в окне [%s, %s] до загрузки: %d", ws, we, pre_cnt)

    # 2. Delete
    logger.info("Удаление строк в окне [%s, %s]", ws, we)
    client.execute(
        f"ALTER TABLE {TABLE_NAME} DELETE "
        f"WHERE day >= toDate('{ws}') AND day <= toDate('{we}')",
        settings={"mutations_sync": 1},
    )

    # 3. Post-delete check
    post_delete_cnt = client.execute(
        f"SELECT count(*) FROM {TABLE_NAME} "
        f"WHERE day >= toDate('{ws}') AND day <= toDate('{we}')"
    )[0][0]
    logger.info("Строк после удаления: %d", post_delete_cnt)
    if post_delete_cnt != 0:
        raise AirflowFailException(
            f"После удаления осталось {post_delete_cnt} строк "
            f"в окне [{ws}, {we}]. ОСТАНОВКА."
        )

    # 4. Insert
    logger.info("Вставка данных для окна [%s, %s]", ws, we)
    client.execute(build_insert_sql_window(ws, we))

    # 5. Post-insert check
    post_insert_cnt = client.execute(
        f"SELECT count(*) FROM {TABLE_NAME} "
        f"WHERE day >= toDate('{ws}') AND day <= toDate('{we}')"
    )[0][0]
    logger.info("Строк после вставки: %d", post_insert_cnt)
    if post_insert_cnt == 0:
        raise AirflowFailException(
            f"После вставки нет строк в окне [{ws}, {we}]. ОСТАНОВКА."
        )

    logger.info("[done] Окно [%s, %s] загружено, строк: %d", ws, we, post_insert_cnt)
