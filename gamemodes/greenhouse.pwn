#include <a_samp>
#include <streamer>

#define MAX_GREENHOUSES     5000    // 1000 игроков * 5
#define MAX_PER_PLAYER      5
#define GROWTH_INTERVAL     6000    // 6 секунд = 1 тик
#define GROWTH_PER_TICK     1.0     // 1% за тик = 100% за 10 минут

enum E_GREENHOUSE
{
    gh_id,                  // ID в базе данных
    gh_owner,               // playerid владельца
    Float:gh_x,
    Float:gh_y,
    Float:gh_z,
    Float:gh_growth,        // 0.0 - 100.0
    gh_upgraded,            // 0 или 1
    gh_timer,               // ID таймера
    gh_object,              // ID объекта streamer
    gh_stage                // визуальная стадия 0/1/2
}

new GreenhouseData[MAX_GREENHOUSES][E_GREENHOUSE];
new GreenhouseCount = 0; // общее кол-во загруженных теплиц

// индекс теплиц по игроку: PlayerGreenhouses[playerid] = {idx1, idx2, ...}
new PlayerGreenhouses[MAX_PLAYERS][MAX_PER_PLAYER];
new PlayerGreenhouseCount[MAX_PLAYERS];

main() {}

public OnGameModeInit()
{
    print("Greenhouse gamemode loaded.");
    SetGameModeText("Greenhouse");

    // Инициализация БД
    new DB:db = db_open("greenhouse.db");
    db_query(db, "CREATE TABLE IF NOT EXISTS greenhouses (id INTEGER PRIMARY KEY AUTOINCREMENT, owner_id INTEGER, pos_x REAL DEFAULT 0.0, pos_y REAL DEFAULT 0.0, pos_z REAL DEFAULT 0.0, growth REAL DEFAULT 0.0, upgraded INTEGER DEFAULT 0)");

    db_close(db);

    print("Database initialized.");
    return 1;
}

public OnGameModeExit()
{
    print("Greenhouse gamemode unloaded.");
    return 1;
}

public OnPlayerConnect(playerid)
{
    // Сбросить индекс теплиц игрока
    PlayerGreenhouseCount[playerid] = 0;
    for(new i = 0; i < MAX_PER_PLAYER; i++)
        PlayerGreenhouses[playerid][i] = -1;

    LoadPlayerGreenhouses(playerid);

    SendClientMessage(playerid, 0x00FF00FF, "Welcome! Greenhouses loaded.");
    return 1;
}

public OnPlayerDisconnect(playerid, reason)
{
    SavePlayerGreenhouses(playerid);
    UnloadPlayerGreenhouses(playerid);
    return 1;
}

// ===================== ФУНКЦИИ БД =====================

LoadPlayerGreenhouses(playerid)
{
    new DB:db = db_open("greenhouse.db");
    new DBResult:result;
    new query[128];
    format(query, sizeof(query), "SELECT * FROM greenhouses WHERE owner_id = %d", playerid);
    result = db_query(db, query);

    if(db_num_rows(result) > 0)
    {
        do
        {
            new idx = GreenhouseCount;
            if(idx >= MAX_GREENHOUSES) break;

            GreenhouseData[idx][gh_id]       = db_get_field_assoc_int(result, "id");
            GreenhouseData[idx][gh_owner]    = playerid;
            GreenhouseData[idx][gh_x]        = db_get_field_assoc_float(result, "pos_x");
            GreenhouseData[idx][gh_y]        = db_get_field_assoc_float(result, "pos_y");
            GreenhouseData[idx][gh_z]        = db_get_field_assoc_float(result, "pos_z");
            GreenhouseData[idx][gh_growth]   = db_get_field_assoc_float(result, "growth");
            GreenhouseData[idx][gh_upgraded] = db_get_field_assoc_int(result, "upgraded");
            GreenhouseData[idx][gh_timer]    = -1;
            GreenhouseData[idx][gh_object]   = -1;
            GreenhouseData[idx][gh_stage]    = -1;

            // Запустить таймер роста
            StartGreenhouseTimer(idx);
            UpdateGreenhouseObject(idx);

            // Запомнить индекс у игрока
            new pc = PlayerGreenhouseCount[playerid];
            if(pc < MAX_PER_PLAYER)
            {
                PlayerGreenhouses[playerid][pc] = idx;
                PlayerGreenhouseCount[playerid]++;
            }

            GreenhouseCount++;
        }
        while(db_next_row(result));
    }

    db_free_result(result);
    db_close(db);
}

SavePlayerGreenhouses(playerid)
{
    new DB:db = db_open("greenhouse.db");
    new query[256];

    for(new i = 0; i < PlayerGreenhouseCount[playerid]; i++)
    {
        new idx = PlayerGreenhouses[playerid][i];
        if(idx == -1) continue;

        format(query, sizeof(query),
            "UPDATE greenhouses SET growth = %.2f, upgraded = %d WHERE id = %d",
            GreenhouseData[idx][gh_growth],
            GreenhouseData[idx][gh_upgraded],
            GreenhouseData[idx][gh_id]
        );
        db_query(db, query);
    }

    db_close(db);
}

UnloadPlayerGreenhouses(playerid)
{
    for(new i = 0; i < PlayerGreenhouseCount[playerid]; i++)
    {
        new idx = PlayerGreenhouses[playerid][i];
        if(idx == -1) continue;

        // Остановить таймер
        if(GreenhouseData[idx][gh_timer] != -1)
        {
            KillTimer(GreenhouseData[idx][gh_timer]);
            GreenhouseData[idx][gh_timer] = -1;
        }

        // Удалить объект
        if(GreenhouseData[idx][gh_object] != -1)
        {
            DestroyDynamicObject(GreenhouseData[idx][gh_object]);
            GreenhouseData[idx][gh_object] = -1;
        }

        // Очистить слот
        GreenhouseData[idx][gh_owner] = -1;

        // Сдвинуть GreenhouseCount если это последний
        if(idx == GreenhouseCount - 1)
            GreenhouseCount--;
    }

    PlayerGreenhouseCount[playerid] = 0;
    for(new i = 0; i < MAX_PER_PLAYER; i++)
        PlayerGreenhouses[playerid][i] = -1;
}

// ===================== ТАЙМЕРЫ =====================

StartGreenhouseTimer(idx)
{
    // Не запускать если уже созрела
    if(GreenhouseData[idx][gh_growth] >= 100.0) return;

    // Убить старый таймер если есть
    if(GreenhouseData[idx][gh_timer] != -1)
        KillTimer(GreenhouseData[idx][gh_timer]);

    new interval = GROWTH_INTERVAL;
    if(GreenhouseData[idx][gh_upgraded]) interval /= 2;

    GreenhouseData[idx][gh_timer] = SetTimerEx("OnGreenhouseTick", interval, true, "i", idx);
}

forward OnGreenhouseTick(idx);
public OnGreenhouseTick(idx)
{
    if(GreenhouseData[idx][gh_growth] >= 100.0) return;

    GreenhouseData[idx][gh_growth] += GROWTH_PER_TICK;
    if(GreenhouseData[idx][gh_growth] > 100.0)
        GreenhouseData[idx][gh_growth] = 100.0;

    UpdateGreenhouseObject(idx);
}
// ===================== КОМАНДЫ =====================

public OnPlayerCommandText(playerid, cmdtext[])
{
    // /creategh — создать теплицу
    if(strcmp(cmdtext, "/creategh", true) == 0)
    {
        if(PlayerGreenhouseCount[playerid] >= MAX_PER_PLAYER)
        {
            SendClientMessage(playerid, 0xFF0000FF, "У вас уже 5 теплиц.");
            return 1;
        }

        new Float:x, Float:y, Float:z;
        GetPlayerPos(playerid, x, y, z);

        // Создать запись в БД
        new DB:db = db_open("greenhouse.db");
        new query[256];
        format(query, sizeof(query),
            "INSERT INTO greenhouses (owner_id, pos_x, pos_y, pos_z, growth, upgraded) VALUES (%d, %.2f, %.2f, %.2f, 0.0, 0)",
            playerid, x, y, z
        );
        db_query(db, query);
        new DBResult:r = db_query(db, "SELECT MAX(id) FROM greenhouses");
        new newId = db_get_field_int(r, 0);
        db_free_result(r);
        db_close(db);

        // Добавить в массив
        new idx = GreenhouseCount;
        GreenhouseData[idx][gh_id]       = newId;
        GreenhouseData[idx][gh_owner]    = playerid;
        GreenhouseData[idx][gh_x]        = x;
        GreenhouseData[idx][gh_y]        = y;
        GreenhouseData[idx][gh_z]        = z;
        GreenhouseData[idx][gh_growth]   = 0.0;
        GreenhouseData[idx][gh_upgraded] = 0;
        GreenhouseData[idx][gh_timer]    = -1;
        GreenhouseData[idx][gh_object]   = -1;
        GreenhouseData[idx][gh_stage]    = -1;

        new pc = PlayerGreenhouseCount[playerid];
        PlayerGreenhouses[playerid][pc] = idx;
        PlayerGreenhouseCount[playerid]++;
        GreenhouseCount++;

        StartGreenhouseTimer(idx);

        SendClientMessage(playerid, 0x00FF00FF, "The greenhouse is created! The harvest will ripen in 10 minutes.");
        return 1;
    }

    // /upgradegh — улучшить теплицу рядом
    if(strcmp(cmdtext, "/upgradegh", true) == 0)
    {
        new idx = GetNearbyGreenhouse(playerid);
        if(idx == -1)
        {
            SendClientMessage(playerid, 0xFF0000FF, "You are not near the greenhouse.");
            return 1;
        }
        if(GreenhouseData[idx][gh_upgraded])
        {
            SendClientMessage(playerid, 0xFF0000FF, "The greenhouse has already been improved.");
            return 1;
        }

        GreenhouseData[idx][gh_upgraded] = 1;

        // Перезапустить таймер с новым интервалом
        KillTimer(GreenhouseData[idx][gh_timer]);
        StartGreenhouseTimer(idx);

        // Сохранить
        new DB:db = db_open("greenhouse.db");
        new query[128];
        format(query, sizeof(query),
            "UPDATE greenhouses SET upgraded = 1 WHERE id = %d",
            GreenhouseData[idx][gh_id]
        );
        db_query(db, query);
        db_close(db);

        SendClientMessage(playerid, 0x00FF00FF, "Greenhouse upgraded! Growth speed increased by 2x.");
        return 1;
    }

    // /collectgh — собрать урожай
    if(strcmp(cmdtext, "/collectgh", true) == 0)
    {
        new idx = GetNearbyGreenhouse(playerid);
        if(idx == -1)
        {
            SendClientMessage(playerid, 0xFF0000FF, "You are not near the greenhouse.");
            return 1;
        }
        if(GreenhouseData[idx][gh_growth] < 100.0)
        {
            new msg[64];
            format(msg, sizeof(msg), "The harvest is not yet ripe. Progress: %.0f%%", GreenhouseData[idx][gh_growth]);
            SendClientMessage(playerid, 0xFFFF00FF, msg);
            return 1;
        }

        GreenhouseData[idx][gh_growth] = 0.0;
        // Сбросить визуал
        if(GreenhouseData[idx][gh_object] != -1)
        {
            DestroyDynamicObject(GreenhouseData[idx][gh_object]);
            GreenhouseData[idx][gh_object] = -1;
        }
        GreenhouseData[idx][gh_stage] = -1;
        UpdateGreenhouseObject(idx);

        new DB:db = db_open("greenhouse.db");
        new query[128];
        format(query, sizeof(query),
            "UPDATE greenhouses SET growth = 0.0 WHERE id = %d",
            GreenhouseData[idx][gh_id]
        );
        db_query(db, query);
        db_close(db);

        SendClientMessage(playerid, 0x00FF00FF, "The harvest is in! The tomatoes are in.");
        return 1;
    }

    // /ghstatus — статус теплиц
    if(strcmp(cmdtext, "/ghstatus", true) == 0)
    {
        new msg[128];
        format(msg, sizeof(msg), "Your greenhouses: %d / %d", PlayerGreenhouseCount[playerid], MAX_PER_PLAYER);
        SendClientMessage(playerid, 0xFFFFFFFF, msg);

        for(new i = 0; i < PlayerGreenhouseCount[playerid]; i++)
        {
            new idx = PlayerGreenhouses[playerid][i];
            if(idx == -1) continue;
            new statusStr[16];
            if(GreenhouseData[idx][gh_upgraded]) statusStr = "[UPGRADED]";
            else statusStr = "[NORMAL]";
            format(msg, sizeof(msg), "  Greenhouse %d: %.0f%% %s", i + 1, GreenhouseData[idx][gh_growth], statusStr);
            SendClientMessage(playerid, 0xFFFFFFFF, msg);
        }
        return 1;
    }

    return 0;
}

// ===================== ХЕЛПЕРЫ =====================

GetNearbyGreenhouse(playerid)
{
    for(new i = 0; i < PlayerGreenhouseCount[playerid]; i++)
    {
        new idx = PlayerGreenhouses[playerid][i];
        if(idx == -1) continue;

        if(IsPlayerInRangeOfPoint(playerid, 3.0,
            GreenhouseData[idx][gh_x],
            GreenhouseData[idx][gh_y],
            GreenhouseData[idx][gh_z]))
        {
            return idx;
        }
    }
    return -1;
}
// ===================== ВИЗУАЛ =====================

GetGreenhouseStage(Float:growth)
{
    if(growth < 33.0) return 0;
    if(growth < 66.0) return 1;
    return 2;
}

UpdateGreenhouseObject(idx)
{
    new stage = GetGreenhouseStage(GreenhouseData[idx][gh_growth]);
    if(stage == GreenhouseData[idx][gh_stage]) return; // стадия не изменилась

    // Удалить старый объект
    if(GreenhouseData[idx][gh_object] != -1)
    {
        DestroyDynamicObject(GreenhouseData[idx][gh_object]);
        GreenhouseData[idx][gh_object] = -1;
    }

    new Float:x = GreenhouseData[idx][gh_x];
    new Float:y = GreenhouseData[idx][gh_y];
    new Float:z = GreenhouseData[idx][gh_z];

    // Объект теплицы — модель 647 (ящик/контейнер, есть в GTA SA)
    // Стадия 0: пустая теплица
    // Стадия 1: 1 ящик рядом
    // Стадия 2: 2 ящика рядом
    switch(stage)
    {
        case 0:
        {
            GreenhouseData[idx][gh_object] = CreateDynamicObject(647, x, y, z, 0.0, 0.0, 0.0);
        }
        case 1:
        {
            GreenhouseData[idx][gh_object] = CreateDynamicObject(647, x, y, z, 0.0, 0.0, 0.0);
            CreateDynamicObject(647, x + 1.5, y, z, 0.0, 0.0, 0.0);
        }
        case 2:
        {
            GreenhouseData[idx][gh_object] = CreateDynamicObject(647, x, y, z, 0.0, 0.0, 0.0);
            CreateDynamicObject(647, x + 1.5, y, z, 0.0, 0.0, 0.0);
            CreateDynamicObject(647, x - 1.5, y, z, 0.0, 0.0, 0.0);
        }
    }

    GreenhouseData[idx][gh_stage] = stage;
}