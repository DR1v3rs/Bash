#!/bin/bash

# Credentials
PJT_NAME="USNA"                                    						# ИМЯ ПРОЕКТА

# Локальные переменные
LOG_FILE="BackUp_${PJT_NAME}.log"						  				# ИМЯ ЛОГ ФАЙЛА

# Глобальные переменные
LOG__DIR="/media/log"				      					  			# ПАПКА ДЛЯ ХРАНЕНИЯ ЛОГОВ
BACK_DIR="/media/backup"								      			# ПАПКА ДЛЯ ХРАНЕНИЯ РЕЗЕРВНЫХ КОПИЙ
CHNG_DIR="/media/changes"								      			# ПАПКА ДЛЯ ХРАНЕНИЯ ПОДРОБНЫХ ИЗМЕНЕНИЙ
PJT__DIR="/mnt/$PJT_NAME"										       	# ПАПКА С ПРОЕКТОМ НА ИНЖЕНЕРКЕ 
SERV_DIR="/mnt/server"										      		# ПАПКА НА СЕРВЕРЕ ДЛЯ ХРАНЕНИЯ РЕЗЕРВНЫХ КОПИЙ

LOG__PNT="${LOG__DIR}/${LOG_FILE}"										# АДРЕС ФАЙЛА ДЛЯ ХРАНЕНИЯ ЛОГОВ
CHNG_PNT="/media/${PJT_NAME}_CHANGE.txt"            					# АДРЕС ФАЙЛА ДЛЯ СПИСКА ИЗМЕНЕНИЙ
EXCL_LST="$(dirname "$0")/excl_fil.txt"             					# АДРЕС ФАЙЛА ДЛЯ СПИСКА ИСКЛЮЧЕНИЙ

SHOP__NO=$(hostname | rev | cut -c3-4 | rev)       						# НОМЕР ЦЕХА
ERROR_SH="/media/scripts/99_error_log.sh"
CLMN_WDT=70

# Проверка на root
[ "$(id -u)" -ne 0 ] && { echo "Ошибка: Требуются права root!" >&2; exit 1; }

# !------------------------------------- ФУНКЦИИ -------------------------------------!
# Функция для записи в лог
log_message() {
    local msg="$1"
    local log_file="$2"
    local msg_len=${#msg}
    local adjus_len=$msg_len
    local forma_msg
    
    # Грубая корректировка для эмодзи
    [[ "$msg" =~ ✅ ]] && adjus_len=$((adjus_len + 1))
    [[ "$msg" =~ ❌ ]] && adjus_len=$((adjus_len + 1))
    [[ "$msg" =~ ⛔ ]] && adjus_len=$((adjus_len + 1))
    
    [ $adjus_len -lt $CLMN_WDT ] && forma_msg=$(printf "%s%$((CLMN_WDT - adjus_len))s |" "$msg" "") || forma_msg=$(printf "%s |" "$msg")
    
    mkdir -p "${LOG__DIR}" 2>/dev/null && echo "|$(date '+%Y.%m.%d %H:%M:%S')| $forma_msg" >> "$log_file"
}

# Функция записи критических сообщений
error_log() { 
    local message="$1"
    [ -f "$ERROR_SH" ] && "$ERROR_SH" "SHOP${SHOP__NO}: ${message}" || \
        echo "ОШИБКА: $ERROR_SH не найден! ${SHOP__NO}: ${message}" | tee -a "$LOG__PNT"
}

# Функция для проверки существования папок
dir_exist() {
    local PATH_DIR="$1"
    
    log_message "►  Проверка наличия директории: $PATH_DIR" "$LOG__PNT"
    
    [ -d "$PATH_DIR" ] && log_message "✅ Директория существует: $PATH_DIR" "$LOG__PNT" && return 0
    
    log_message "►  Создаем директорию: $PATH_DIR" "$LOG__PNT"
    mkdir -p "$PATH_DIR" && log_message "✅ Директория успешно создана: $PATH_DIR" "$LOG__PNT" || {
        log_message "❌ Ошибка: Не удалось создать директорию: $PATH_DIR" "$LOG__PNT" >&2
        return 1
    }
}

# Функция проверки монтирования папок.
mount_point() {
    local MNT__PNT="$1"
    local ERROR_MSG="$2"

    dir_exist "$MNT__PNT"
    log_message "►  Проверяем монтирование директории: $MNT__PNT" "$LOG__PNT"
    if mountpoint -q "$MNT__PNT"; then
        log_message "✅ Директория примонтирована: $MNT__PNT" "$LOG__PNT"
        return 0
    else
        log_message "❌ Директория не примонтирована: $MNT__PNT" "$LOG__PNT"
        log_message "►  Монтируем сетевую директорию: $MNT__PNT" "$LOG__PNT"
        if mount "$MNT__PNT" 2>/dev/null; then
            log_message "✅ Директория примонтирована: $MNT__PNT" "$LOG__PNT"
            return 0
        else
            
			
			log_message "⛔ ОШИБКА МОНТИРОВАНИЯ! $MNT__PNT $ERROR_MSG" "$LOG__PNT"
            error_log   "⛔ КРИТИЧЕСКАЯ ОШИБКА! Не возможно примонтировать папку: $MNT__PNT" "$LOG__PNT"
            return 1
        fi
    fi
}

# Функция для проверки, нужно ли исключить файл
should_exclude_file() {
    local file="$1"
    local filename=$(basename "$file")
    
    [ ! -f "$EXCL_LST" ] && return 1
    
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
        pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # case сам поддерживает wildcard, отдельная проверка не нужна
        case "$filename" in ($pattern) return 0;; esac
        case "$file" in (*"$pattern"*) return 0;; esac
    done < "$EXCL_LST"
    
    return 1
}

# Функция для вычисления контрольной суммы папки
calculate_checksum() {
    [ ! -d "$PJT__PNT" ] && { echo "0"; return 1; }
    
    local result
    if command -v parallel >/dev/null 2>&1; then
        result=$(find "$PJT__PNT" -type f -print0 2>/dev/null | parallel -0 -j $(nproc) -- md5sum 2>/dev/null)
    else
        result=$(find "$PJT__PNT" -type f -exec stat -c '%n %s %Y' {} \; 2>/dev/null)
    fi
    echo "$result" | sort | md5sum | cut -d' ' -f1 | sed 's/^$/0/'
}

# Функция для поиска измененных файлов
find_changed_files() {
    local changed_files=""
    local current_state=$(mktemp)
    local previous_state=$(mktemp)
    
    # Создаем текущее состояние с абсолютными путями
    find "$PJT__PNT" -type f -printf "%p\t%T@\t%s\n" 2>/dev/null | sort > "$current_state"
    
    # Если есть предыдущее состояние
    if [ -f "$CHNG_FIL.prev" ]; then
        # Создаем копию для сравнения
        cp "$CHNG_FIL.prev" "$previous_state"
        
        # Ищем только измененные файлы (без дубликатов)
        changed_files=$(diff --unchanged-group-format='' --changed-group-format='%>' \
            "$previous_state" "$current_state" 2>/dev/null | cut -f1 | sort -u)
        
        # Также ищем удаленные файлы (только уникальные)
        local deleted_files=$(diff --unchanged-group-format='' --new-group-format='' --old-group-format='%>' \
            "$current_state" "$previous_state" 2>/dev/null | cut -f1 | sort -u)
        
        if [ -n "$deleted_files" ]; then
            changed_files=$(echo -e "$changed_files\n$deleted_files" | sed '/^$/d' | sort -u)
        fi
    fi
    
    # Сохраняем текущее состояние для следующего запуска
    mv "$current_state" "$CHNG_FIL.prev" 2>/dev/null
    
    # Очищаем временные файлы
    rm -f "$current_state" "$previous_state" 2>/dev/null
    
    echo "$changed_files"
}

# Функция для фильтрации измененных файлов (исключая определенные имена)  (Объеденить с предыдущей )
filter_changed_files() {
    local changed_files="$1"
    local filtered_files=""
    
    if [ -z "$changed_files" ]; then
        echo ""
        return
    fi
    
    while IFS= read -r file; do
        if [ -n "$file" ] && ! should_exclude_file "$file"; then
            filtered_files="${filtered_files}${file}"$'\n'
        fi
    done <<< "$changed_files"
    
    echo "$filtered_files"
}

# !---------------------------------- НАЧАЛО РАБОТЫ СКРИПТА ----------------------------------!
echo "+$(printf '%0.s-' {1..19})+$(printf '%0.s-' {1..72})+" >> "$LOG__PNT"                     # ПИШЕМ РАЗДЕЛИТЕЛЬ ЛОГ
log_message "►  Запуск скрипта: $(basename "$0")" "$LOG__PNT"                                   # ПИШЕМ В ЛОГ

# ПРОВЕРЯЕМ СМОНТИРОВАНЫ ЛИ УДАЛЁННЫЕ ПАПКИ
mount_point "$PJT__DIR" "ОШИБКА: Не удалось примонтировать. Скрипт завершён." || exit 1         # МОНТРИУЕМ ПАПКУ С ПРОЕКТОМ
mount_point "$SERV_DIR" "ОШИБКА: Не удалось примонтировать."                                    # МОНТРИУЕМ ПАПКУ НА СЕРВЕРЕ

# Моздаём переменные для путей
PJT__PNT=$(find "$PJT__DIR" -maxdepth 1 -type d -not -path "$PJT__DIR" | head -1)
MD_SUM_F="/tmp/.checksum_$(basename "$PJT__PNT")"
CHNG_FIL="/tmp/.changes_$(basename "$PJT__PNT")"
CHNG_PNT="${LOG__DIR}/$(basename "$PJT__PNT")_CHANGE.txt"

# ПРОВЕРЯЕМ НАЛИЧИЕ ПАПОК
dir_exist "$CHNG_DIR"                                                                           # ПРОВЕРЯЕМ ЕСТЬ ЛИ ПАПКА ДЛЯ ИНФОРМАЦИИ ПО ИЗМЕНЕНИЯМ
dir_exist "$BACK_DIR"                                                                           # ПРОВЕРЯЕМ ЕСТЬ ЛИ ПАПКА ДЛЯ ХРАНЕНИЯ БЕКАПОВ НА ЛОКАЛЬНОМ КОМПЬЮТЕРЕ

# ВЫЧИСЛЯЕМ КОНТРОЛЬНУЮ СУММУ
CORR_SUM=$(calculate_checksum)                                                                  # ВЫЧИСЛЯЕМ НОВУЮ КОНТРОЛЬНУЮ СУММУ ПАПКИ С ПРОЕКТОМ
log_message "✅ Контрольная сумма проекта: $CORR_SUM" "$LOG__PNT"                               # ПИШЕМ В ЛОГ

# Проверяем, существует ли предыдущая контрольная сумма
if [ -f "$MD_SUM_F" ]; then                                                                     # ПРОВЕРЯЕМ ЕСТЬ ЛИ СТАРАЯ КОНТРОЛЬНАЯ СУММА, ЕСЛИ ЕСТЬ ТО...
    LAST_SUM=$(cat "$MD_SUM_F")                                                                 # ЗАПИСЫВАЕМ ПРОШЛУЮ КОНТРОЛЬНУЮ СУММУ В ПЕРЕМЕННУЮ
    
    # Если есть изменения
    if [ "$CORR_SUM" != "$LAST_SUM" ]; then                                                     # СРАВНИВАЕМ СТАРУЮ И НОВУЮ КОНТРОЛЬНУЮ СУММУ
        log_message "►  Обнаружены изменения в папке!" "$LOG__PNT"                              # ПИШЕМ В ЛОГ
        
        # ФОРМУРУЕМ ИМЯ АРХИВА
        CURR_DAT=$(date +"%Y_%m_%d")                                                            # ФОРМИРУЕМ ДАТУ ДЛЯ ФАЙЛА АРХИВА
        ARCH_NAM="SHOP${SHOP__NO}_$(basename "$PJT__PNT")_VP_${CURR_DAT}.zip"                               # ФОРМИРУЕМ ИМЯ ФАЙЛА АРХИВА
        ARCH_PAT="${BACK_DIR}/${ARCH_NAM}"                                                      # ФОРМИРУЕМ ПОЛНЫЙ АДРЕС ДЛЯ ХРАНЕНИЯ АРХИВА
        
        # Ищем измененные файлы
        log_message "►  Поиск измененных файлов..." "$LOG__PNT"                                 # ПИШЕМ В ЛОГ
        FILT_FIL=$(filter_changed_files "$(find_changed_files)")                                # 
		
		    # Создаем архив
        log_message "►  Создание архива: $ARCH_PAT" "$LOG__PNT"                                 # ПИШЕМ В ЛОГ
        cd "$PJT__DIR" || exit 1                                                                # ПЕРЕХОДИМ В ПАПКУ С ПРОЕКТОМ ЕСЛИ НЕ ПОЛУЧИЛОСЬ ТО ВЫХОДИМ И СКРИПТА
        
        if zip -r "$ARCH_PAT" . > /dev/null 2>&1; then                                          # СОЗДАЁМ АРХИВ ПАПКИ С ПРОЕКТОМ
            log_message "✅ Архив успешно создан: $ARCH_PAT" "$LOG__PNT"                        # ПИШЕМ В ЛОГ
        else                                                                                    # еСЛИ НЕ УДАЛОСЬ СОЗДАТЬ АРХИВ, ТО
            log_message "⛔ ОШИБКА: Не удалось создать архив!" "$LOG__PNT"                      # ПИШЕМ В ЛОГ
            exit 1                                                                              # ВЫХОД ИЗ СКРИПТА
        fi                                                                                      # -

        # Создаем файл со списком изменений
        {
            if [ -n "$FILT_FIL" ]; then
                echo "$FILT_FIL"
                echo "========================================="
                echo "Изменения внесённый с $(date '+%Y.%m.%d %H:%M:%S')"
            else
                echo "Не удалось определить конкретные измененные файлы"
            fi
        } > "$CHNG_PNT"
        
        if mountpoint -q "$SERV_DIR"; then
            cp "$ARCH_PAT" "$SERV_DIR/" 2>/dev/null && log_message "✅ Архив скопирован на сервер" "$LOG__PNT"
            cp "$CHNG_PNT" "$SERV_DIR/" 2>/dev/null && log_message "✅ Список изменений скопирован на сервер" "$LOG__PNT"
        fi
        
    else
        log_message "✅ Изменений не обнаружено." "$LOG__PNT"
    fi
else
    log_message "✅ Первоначальная контрольная сумма создана." "$LOG__PNT"
fi
echo "+$(printf '%0.s-' {1..19})+$(printf '%0.s-' {1..72})+" >> "$LOG__PNT"                     # ПИШЕМ РАЗДЕЛИТЕЛЬ ЛОГ

# Сохраняем текущую контрольную сумму
echo "$CORR_SUM" > "$MD_SUM_F"