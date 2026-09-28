---@mod org.agenda.calendars Other calendars, moon phases, sunrise and holidays for the agenda
---
--- Ports of the Emacs calendar commands the agenda runs on the date at point
--- (org-agenda-convert-date, org-agenda-phases-of-moon,
--- org-agenda-sunrise-sunset, org-agenda-holidays): the date strings of
--- calendar.el, cal-iso.el, cal-julian.el, cal-hebrew.el, cal-islam.el,
--- cal-french.el, cal-bahai.el, cal-mayan.el, cal-coptic.el, cal-persia.el and
--- cal-china.el, the quarters of the moon of lunar.el and the sunrise/sunset
--- string of solar.el. The output matches Emacs's with the default
--- `calendar-date-display-form' (american style).
---
--- Dates are Emacs "absolute" day numbers (days since the imaginary
--- 1 BC-12-31); `abs = org.date day number + 719163`.

local astro = require("org.agenda.holidays.astro")

local M = {}

local floor = math.floor
local idiv = astro.idiv
local abs_from_greg = astro.absolute_from_gregorian
local greg_from_abs = astro.gregorian_from_absolute

M.EPOCH_ABS = astro.EPOCH_ABS

--- Emacs integer `%` (remainder with the sign of the dividend).
local function erem(a, b)
  return a - idiv(a, b) * b
end

local MONTH_NAMES = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}
local DAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

--- calendar-day-of-week of an absolute date (0 = Sunday).
local function day_of_week(abs)
  return abs % 7
end

--- The `calendar-date-display-form' (american) of MONTHNAME DAY, YEAR,
--- with ", "-separated DAYNAME before it when given.
local function display_form(monthname, day, year, dayname)
  return (dayname and (dayname .. ", ") or "") .. monthname .. " " .. day .. ", " .. year
end

--- calendar-date-string of the Gregorian date of ABS.
---@param abs integer
---@param abbreviate? boolean abbreviated month and day names
---@param nodayname? boolean
---@return string
function M.gregorian_string(abs, abbreviate, nodayname)
  local m, d, y = greg_from_abs(abs)
  local month = MONTH_NAMES[m]
  local dayname = not nodayname and DAY_NAMES[day_of_week(abs) + 1] or nil
  if abbreviate then
    month = month:sub(1, 3)
    dayname = dayname and dayname:sub(1, 3)
  end
  return display_form(month, d, y, dayname)
end

---------------------------------------------------------------------------
-- ISO, day of year, Julian, astronomical day number
---------------------------------------------------------------------------

--- calendar-dayname-on-or-before
local function dayname_on_or_before(dayname, abs)
  return abs - (abs - dayname) % 7
end

--- calendar-iso-to-absolute of WEEK DAY (0 = Sunday) YEAR.
local function iso_to_absolute(week, day, year)
  return dayname_on_or_before(1, 3 + abs_from_greg(1, 1, year)) + 7 * (week - 1) + (day == 0 and 6 or day - 1)
end

--- calendar-iso-date-string: "Day 7 of week 39 of 2026".
---@param abs integer
---@return string
function M.iso_string(abs)
  local _, _, approx = greg_from_abs(abs - 3)
  local year = approx
  while abs >= iso_to_absolute(1, 1, year + 1) do
    year = year + 1
  end
  local week = 1 + idiv(abs - iso_to_absolute(1, 1, year), 7)
  local day = abs % 7
  return string.format("Day %d of week %d of %d", day == 0 and 7 or day, week, year)
end

--- calendar-day-of-year-string: "Day 270 of 2026; 95 days remaining in the year".
---@param abs integer
---@return string
function M.day_of_year_string(abs)
  local m, d, y = greg_from_abs(abs)
  local day = astro.day_number(m, d, y)
  local remaining = astro.day_number(12, 31, y) - day
  return string.format("Day %d of %d; %d day%s remaining in the year", day, y, remaining, remaining == 1 and "" or "s")
end

--- calendar-julian-date-string: "September 14, 2026".
---@param abs integer
---@return string
function M.julian_string(abs)
  local m, d, y = require("org.agenda.holidays.julian").from_absolute(abs)
  return display_form(MONTH_NAMES[m], d, y)
end

--- calendar-astro-date-string: the astronomical (Julian) day number after
--- noon UTC.
---@param abs integer
---@return string
function M.astro_string(abs)
  return tostring(math.ceil(abs + astro.ASTRO))
end

---------------------------------------------------------------------------
-- Hebrew, Islamic, Bahá’í
---------------------------------------------------------------------------

local HEBREW_MONTHS = { "Nisan", "Iyar", "Sivan", "Tammuz", "Av", "Elul", "Tishri", "Heshvan", "Kislev", "Teveth" }
HEBREW_MONTHS[11] = "Shevat"

--- calendar-hebrew-date-string (the date before sunset): "Tishri 16, 5787".
---@param abs integer
---@return string
function M.hebrew_string(abs)
  local m, d, y = require("org.agenda.holidays.hebrew").from_absolute(abs)
  local name = HEBREW_MONTHS[m]
  if not name then
    -- calendar-hebrew-leap-year-p: Adar I and II in leap years
    local leap = (1 + 7 * y) % 19 < 7
    name = leap and (m == 12 and "Adar I" or "Adar II") or "Adar"
  end
  return display_form(name, d, y)
end

local ISLAMIC_MONTHS = {
  "Muharram",
  "Safar",
  "Rabi I",
  "Rabi II",
  "Jumada I",
  "Jumada II",
  "Rajab",
  "Sha'ban",
  "Ramadan",
  "Shawwal",
  "Dhu al-Qada",
  "Dhu al-Hijjah",
}

--- calendar-islamic-date-string (before sunset; "" before the epoch).
---@param abs integer
---@return string
function M.islamic_string(abs)
  local m, d, y = require("org.agenda.holidays.islamic").from_absolute(abs)
  if y < 1 then
    return ""
  end
  return display_form(ISLAMIC_MONTHS[m], d, y)
end

local BAHAI_MONTHS = {
  "Bahá",
  "Jalál",
  "Jamál",
  "‘Aẓamat",
  "Núr",
  "Raḥmat",
  "Kalimát",
  "Kamál",
  "Asmá’",
  "‘Izzat",
  "Mashíyyat",
  "‘Ilm",
  "Qudrat",
  "Qawl",
  "Masá’il",
  "Sharaf",
  "Sulṭán",
  "Mulk",
  "‘Alá’",
}

--- calendar-bahai-date-string (before sunset; "" before the epoch).
---@param abs integer
---@return string
function M.bahai_string(abs)
  local bahai = require("org.agenda.holidays.bahai")
  local m, d, y = bahai.from_absolute(abs)
  if y < 1 then
    return ""
  end
  if m == 19 and d <= 0 then
    return display_form("Ayyám-i-Há", d + (bahai.leap_year_p(y) and 5 or 4), y)
  end
  return display_form(BAHAI_MONTHS[m], d, y)
end

---------------------------------------------------------------------------
-- French Revolutionary calendar (cal-french.el)
---------------------------------------------------------------------------

local FRENCH_EPOCH = abs_from_greg(9, 22, 1792)

local FRENCH_MONTHS = {
  "Vendémiaire",
  "Brumaire",
  "Frimaire",
  "Nivôse",
  "Pluviôse",
  "Ventôse",
  "Germinal",
  "Floréal",
  "Prairial",
  "Messidor",
  "Thermidor",
  "Fructidor",
  "jour complémentaire",
}

local FRENCH_DAYS = { "Primidi", "Duodi", "Tridi", "Quartidi", "Quintidi", "Sextidi", "Septidi", "Octidi", "Nonidi" }
FRENCH_DAYS[10] = "Décadi"

-- calendar-french-feasts-array
local FRENCH_FEASTS = {
  "du Raisin", "du Safran", "de la Châtaigne", "de la Colchique", "du Cheval", "de la Balsamine", "de la Carotte",
  "de l'Amarante", "du Panais", "de la Cuve", "de la Pomme de terre", "de l'Immortelle", "du Potiron", "du Réséda",
  "de l'Âne", "de la Belle de nuit", "de la Citrouille", "du Sarrasin", "du Tournesol", "du Pressoir", "du Chanvre",
  "de la Pêche", "du Navet", "de l'Amaryllis", "du Bœuf", "de l'Aubergine", "du Piment", "de la Tomate", "de l'Orge",
  "du Tonneau", "de la Pomme", "du Céleri", "de la Poire", "de la Betterave", "de l'Oie", "de l'Héliotrope",
  "de la Figue", "de la Scorsonère", "de l'Alisier", "de la Charrue", "du Salsifis", "de la Macre", "du Topinambour",
  "de l'Endive", "du Dindon", "du Chervis", "du Cresson", "de la Dentelaire", "de la Grenade", "de la Herse",
  "de la Bacchante", "de l'Azerole", "de la Garance", "de l'Orange", "du Faisan", "de la Pistache", "du Macjon",
  "du Coing", "du Cormier", "du Rouleau", "de la Raiponce", "du Turneps", "de la Chicorée", "de la Nèfle",
  "du Cochon", "de la Mâche", "du Chou-fleur", "du Miel", "du Genièvre", "de la Pioche", "de la Cire", "du Raifort",
  "du Cèdre", "du Sapin", "du Chevreuil", "de l'Ajonc", "du Cyprès", "du Lierre", "de la Sabine", "du Hoyau",
  "de l'Érable-sucre", "de la Bruyère", "du Roseau", "de l'Oseille", "du Grillon", "du Pignon", "du Liège",
  "de la Truffe", "de l'Olive", "de la Pelle", "de la Tourbe", "de la Houille", "du Bitume", "du Soufre", "du Chien",
  "de la Lave", "de la Terre végétale", "du Fumier", "du Salpêtre", "du Fléau", "du Granit", "de l'Argile",
  "de l'Ardoise", "du Grès", "du Lapin", "du Silex", "de la Marne", "de la Pierre à chaux", "du Marbre", "du Van",
  "de la Pierre à plâtre", "du Sel", "du Fer", "du Cuivre", "du Chat", "de l'Étain", "du Plomb", "du Zinc",
  "du Mercure", "du Crible", "de la Lauréole", "de la Mousse", "du Fragon", "du Perce-neige", "du Taureau",
  "du Laurier-thym", "de l'Amadouvier", "du Mézéréon", "du Peuplier", "de la Cognée", "de l'Ellébore", "du Brocoli",
  "du Laurier", "de l'Avelinier", "de la Vache", "du Buis", "du Lichen", "de l'If", "de la Pulmonaire",
  "de la Serpette", "du Thlaspi", "du Thymelé", "du Chiendent", "de la Traînasse", "du Lièvre", "de la Guède",
  "du Noisetier", "du Cyclamen", "de la Chélidoine", "du Traîneau", "du Tussilage", "du Cornouiller", "du Violier",
  "du Troène", "du Bouc", "de l'Asaret", "de l'Alaterne", "de la Violette", "du Marsault", "de la Bêche",
  "du Narcisse", "de l'Orme", "de la Fumeterre", "du Vélar", "de la Chèvre", "de l'Épinard", "du Doronic",
  "du Mouron", "du Cerfeuil", "du Cordeau", "de la Mandragore", "du Persil", "du Cochléaria", "de la Pâquerette",
  "du Thon", "du Pissenlit", "de la Sylvie", "du Capillaire", "du Frêne", "du Plantoir", "de la Primevère",
  "du Platane", "de l'Asperge", "de la Tulipe", "de la Poule", "de la Blette", "du Bouleau", "de la Jonquille",
  "de l'Aulne", "du Couvoir", "de la Pervenche", "du Charme", "de la Morille", "du Hêtre", "de l'Abeille",
  "de la Laitue", "du Mélèze", "de la Ciguë", "du Radis", "de la Ruche", "du Gainier", "de la Romaine",
  "du Marronnier", "de la Roquette", "du Pigeon", "du Lilas", "de l'Anémone", "de la Pensée", "de la Myrtille",
  "du Greffoir", "de la Rose", "du Chêne", "de la Fougère", "de l'Aubépine", "du Rossignol", "de l'Ancolie",
  "du Muguet", "du Champignon", "de la Jacinthe", "du Rateau", "de la Rhubarbe", "du Sainfoin", "du Bâton-d'or",
  "du Chamérisier", "du Ver à soie", "de la Consoude", "de la Pimprenelle", "de la Corbeille-d'or", "de l'Arroche",
  "du Sarcloir", "du Statice", "de la Fritillaire", "de la Bourrache", "de la Valériane", "de la Carpe", "du Fusain",
  "de la Civette", "de la Buglosse", "du Sénevé", "de la Houlette", "de la Luzerne", "de l'Hémérocalle", "du Trèfle",
  "de l'Angélique", "du Canard", "de la Mélisse", "du Fromental", "du Martagon", "du Serpolet", "de la Faux",
  "de la Fraise", "de la Bétoine", "du Pois", "de l'Acacia", "de la Caille", "de l'Œillet", "du Sureau", "du Pavot",
  "du Tilleul", "de la Fourche", "du Barbeau", "de la Camomille", "du Chèvrefeuille", "du Caille-lait",
  "de la Tanche", "du Jasmin", "de la Verveine", "du Thym", "de la Pivoine", "du Chariot", "du Seigle",
  "de l'Avoine", "de l'Oignon", "de la Véronique", "du Mulet", "du Romarin", "du Concombre", "de l'Échalotte",
  "de l'Absinthe", "de la Faucille", "de la Coriandre", "de l'Artichaut", "de la Giroflée", "de la Lavande",
  "du Chamois", "du Tabac", "de la Groseille", "de la Gesse", "de la Cerise", "du Parc", "de la Menthe", "du Cumin",
  "du Haricot", "de l'Orcanète", "de la Pintade", "de la Sauge", "de l'Ail", "de la Vesce", "du Blé",
  "de la Chalémie", "de l'Épautre", "du Bouillon-blanc", "du Melon", "de l'Ivraie", "du Bélier", "de la Prèle",
  "de l'Armoise", "du Carthame", "de la Mûre", "de l'Arrosoir", "du Panis", "du Salicor", "de l'Abricot",
  "du Basilic", "de la Brebis", "de la Guimauve", "du Lin", "de l'Amande", "de la Gentiane", "de l'Écluse",
  "de la Carline", "du Câprier", "de la Lentille", "de l'Aunée", "de la Loutre", "de la Myrte", "du Colza",
  "du Lupin", "du Coton", "du Moulin", "de la Prune", "du Millet", "du Lycoperdon", "de l'Escourgeon", "du Saumon",
  "de la Tubéreuse", "du Sucrion", "de l'Apocyn", "de la Réglisse", "de l'Échelle", "de la Pastèque", "du Fenouil",
  "de l'Épine-vinette", "de la Noix", "de la Truite", "du Citron", "de la Cardère", "du Nerprun", "du Tagette",
  "de la Hotte", "de l'Églantier", "de la Noisette", "du Houblon", "du Sorgho", "de l'Écrevisse", "de la Bagarade",
  "de la Verge-d'or", "du Maïs", "du Marron", "du Panier", "de la Vertu", "du Génie", "du Travail", "de la Raison",
  "des Récompenses", "de la Révolution",
}

--- calendar-french-leap-year-p
local function french_leap_year_p(year)
  if year == 3 or year == 7 or year == 11 or year == 15 or year == 20 then
    return true
  end
  local r = erem(year, 400)
  return year > 20 and erem(year, 4) == 0 and r ~= 100 and r ~= 200 and r ~= 300 and erem(year, 4000) ~= 0
end

--- calendar-french-last-day-of-month
local function french_last_day_of_month(month, year)
  if month < 13 then
    return 30
  end
  return french_leap_year_p(year) and 6 or 5
end

--- calendar-french-to-absolute
local function french_to_absolute(month, day, year)
  local leap
  if year < 20 then
    leap = idiv(year, 4)
  else
    local y = year - 1
    leap = idiv(y, 4) - idiv(y, 100) + idiv(y, 400) - idiv(y, 4000)
  end
  return 365 * (year - 1) + leap + 30 * (month - 1) + day + (FRENCH_EPOCH - 1)
end

--- calendar-french-date-string ("" before the epoch).
---@param abs integer
---@return string
function M.french_string(abs)
  if abs < FRENCH_EPOCH then
    return ""
  end
  local year = idiv(abs - FRENCH_EPOCH, 366)
  while abs >= french_to_absolute(1, 1, year + 1) do
    year = year + 1
  end
  local month = 1
  while abs > french_to_absolute(month, french_last_day_of_month(month, year), year) do
    month = month + 1
  end
  local day = abs - (french_to_absolute(month, 1, year) - 1)
  if year < 1 then
    return ""
  end
  return string.format(
    "%s %d %s an %d de la Révolution, jour %s",
    FRENCH_DAYS[erem(day - 1, 10) + 1],
    day,
    FRENCH_MONTHS[month],
    year,
    FRENCH_FEASTS[30 * month + day - 30]
  )
end

---------------------------------------------------------------------------
-- Mayan calendar (cal-mayan.el)
---------------------------------------------------------------------------

local MAYAN_DAYS_BEFORE_ABS_ZERO = 1137142
local HAAB_MONTHS =
  { "Pop", "Uo", "Zip", "Zotz", "Tzec", "Xul", "Yaxkin", "Mol", "Chen", "Yax", "Zac", "Ceh", "Mac", "Kankin", "Muan" }
vim.list_extend(HAAB_MONTHS, { "Pax", "Kayab", "Cumku" })
local TZOLKIN_NAMES = {
  "Imix",
  "Ik",
  "Akbal",
  "Kan",
  "Chicchan",
  "Cimi",
  "Manik",
  "Lamat",
  "Muluc",
  "Oc",
  "Chuen",
  "Eb",
  "Ben",
  "Ix",
  "Men",
  "Cib",
  "Caban",
  "Etznab",
  "Cauac",
  "Ahau",
}

--- calendar-mayan-date-string: "Long count = 13.0.13.17.8; tzolkin = 1
--- Lamat; haab = 1 Yax".
---@param abs integer
---@return string
function M.mayan_string(abs)
  local lc = abs + MAYAN_DAYS_BEFORE_ABS_ZERO
  local baktun, r = idiv(lc, 144000), erem(lc, 144000)
  local katun
  katun, r = idiv(r, 7200), erem(r, 7200)
  local tun
  tun, r = idiv(r, 360), erem(r, 360)
  local uinal, kin = idiv(r, 20), erem(r, 20)
  -- calendar-mayan-tzolkin-from-absolute (tzolkin at epoch: 4 Ahau)
  local tz_day = 1 + (lc + 4 - 1) % 13
  local tz_name = 1 + (lc + 20 - 1) % 20
  -- calendar-mayan-haab-from-absolute (haab at epoch: 8 Cumku)
  local day_of_haab = erem(lc + 8 + 20 * (18 - 1), 365)
  local haab_day, haab_month = erem(day_of_haab, 20), 1 + idiv(day_of_haab, 20)
  return string.format(
    "Long count = %d.%d.%d.%d.%d; tzolkin = %d %s; haab = %d %s",
    baktun,
    katun,
    tun,
    uinal,
    kin,
    tz_day,
    TZOLKIN_NAMES[tz_name],
    haab_day,
    haab_month == 19 and "Uayeb" or HAAB_MONTHS[haab_month]
  )
end

---------------------------------------------------------------------------
-- Coptic and Ethiopic calendars (cal-coptic.el)
---------------------------------------------------------------------------

local COPTIC_MONTHS = { "Tut", "Babah", "Hatur", "Kiyahk", "Tubah", "Amshir", "Baramhat", "Barmundah", "Bashans" }
vim.list_extend(COPTIC_MONTHS, { "Baunah", "Abib", "Misra", "al-Nasi" })
local ETHIOPIC_MONTHS = { "Maskaram", "Teqemt", "Khedar", "Takhsas", "Ter", "Yakatit", "Magabit", "Miyazya" }
vim.list_extend(ETHIOPIC_MONTHS, { "Genbot", "Sane", "Hamle", "Nahas", "Paguem" })

--- calendar-coptic-date-string with EPOCH and month NAMES ("" before the epoch).
local function coptic_string(abs, epoch, names)
  if abs < epoch then
    return ""
  end
  local function to_absolute(month, day, year)
    return (epoch - 1) + 365 * (year - 1) + idiv(year, 4) + 30 * (month - 1) + day
  end
  local function last_day(month, year)
    if month < 13 then
      return 30
    end
    return (year + 1) % 4 == 0 and 6 or 5
  end
  local year = idiv(abs - epoch, 366)
  while abs >= to_absolute(1, 1, year + 1) do
    year = year + 1
  end
  local month = 1
  while abs > to_absolute(month, last_day(month, year), year) do
    month = month + 1
  end
  if year < 1 then
    return ""
  end
  return display_form(names[month], abs - (to_absolute(month, 1, year) - 1), year)
end

--- calendar-coptic-date-string: "Tut 17, 1743".
---@param abs integer
---@return string
function M.coptic_string(abs)
  local julian = require("org.agenda.holidays.julian")
  return coptic_string(abs, julian.to_absolute(8, 29, 284), COPTIC_MONTHS)
end

--- calendar-ethiopic-date-string: "Maskaram 17, 2019".
---@param abs integer
---@return string
function M.ethiopic_string(abs)
  return coptic_string(abs, 2796, ETHIOPIC_MONTHS)
end

---------------------------------------------------------------------------
-- Persian calendar (cal-persia.el)
---------------------------------------------------------------------------

local PERSIAN_MONTHS = { "Farvardin", "Ordibehest", "Xordad", "Tir", "Mordad", "Sahrivar", "Mehr", "Aban", "Azar" }
vim.list_extend(PERSIAN_MONTHS, { "Dey", "Bahman", "Esfand" })

local persian_epoch

--- calendar-persian-leap-year-p
local function persian_leap_year_p(year)
  return (((year >= 0 and year + 2346 or year + 2347) % 2820) % 768 * 683) % 2820 < 683
end

--- calendar-persian-last-day-of-month
local function persian_last_day_of_month(month, year)
  if month < 7 then
    return 31
  elseif month < 12 or persian_leap_year_p(year) then
    return 30
  end
  return 29
end

--- calendar-persian-to-absolute
local function persian_to_absolute(month, day, year)
  if year < 0 then
    return persian_to_absolute(month, day, 1 + year % 2820) + 1029983 * floor(year / 2820)
  end
  local months = 0
  for m = 1, month - 1 do
    months = months + persian_last_day_of_month(m, year)
  end
  return (persian_epoch - 1)
    + 365 * (year - 1)
    + 683 * floor((year + 2345) / 2820)
    + 186 * floor(((year + 2345) % 2820) / 768)
    + floor(683 * (((year + 2345) % 2820) % 768) / 2820)
    - 568
    + months
    + day
end

--- calendar-persian-year-from-absolute
local function persian_year_from_absolute(abs)
  local d0 = abs - persian_to_absolute(1, 1, -2345)
  local n2820 = floor(d0 / 1029983)
  local d1 = d0 % 1029983
  local n768 = floor(d1 / 280506)
  local d2 = d1 % 280506
  local n1 = floor(2820 * (d2 + 366) / 1029983)
  local year = 2820 * n2820 + 768 * n768 + (d1 == 1029617 and n1 - 1 or n1) - 2345
  return year < 1 and year - 1 or year
end

--- calendar-persian-date-string: "Mehr 5, 1405".
---@param abs integer
---@return string
function M.persian_string(abs)
  persian_epoch = persian_epoch or require("org.agenda.holidays.julian").to_absolute(3, 19, 622)
  local year = persian_year_from_absolute(abs)
  local month = 1
  while abs > persian_to_absolute(month, persian_last_day_of_month(month, year), year) do
    month = month + 1
  end
  return display_form(PERSIAN_MONTHS[month], abs - (persian_to_absolute(month, 1, year) - 1), year)
end

---------------------------------------------------------------------------
-- Chinese calendar (cal-china.el)
---------------------------------------------------------------------------

--- calendar-chinese-date-string: "Cycle 78, year 43 (Bing-Wu), month 8
--- (Ding-You), day 17 (Jia-Chen)"; nil where Emacs signals an error (years
--- before 1 AD).
---@param abs integer
---@return string?
function M.chinese_string(abs)
  local chinese = require("org.agenda.holidays.chinese")
  local ok, res = pcall(function()
    local cycle, year, month, day = chinese.from_absolute(abs)
    local this_month = chinese.to_absolute(cycle, year, month, 1)
    local fm = floor(month)
    local next_month =
      chinese.to_absolute(year == 60 and cycle + 1 or cycle, fm == 12 and year + 1 or year, 1 + fm % 12, 1)
    local leap = month ~= fm
    local prefix = leap and "second " or ((next_month - this_month > 30) and "first " or "")
    return string.format(
      "Cycle %d, year %d (%s), %smonth %d%s, day %d (%s)",
      cycle,
      year,
      chinese.sexagesimal_name(year),
      prefix,
      fm,
      leap and "" or string.format(" (%s)", chinese.sexagesimal_name(12 * year + month + 50)),
      day,
      chinese.sexagesimal_name(abs + 15)
    )
  end)
  return ok and res or nil
end

---------------------------------------------------------------------------
-- org-agenda-convert-date
---------------------------------------------------------------------------

--- The lines org-agenda-convert-date shows in its *Dates* buffer.
---@param abs integer
---@return string[]
function M.convert_lines(abs)
  local function safe(fn)
    local ok, s = pcall(fn, abs)
    return ok and s or ""
  end
  return {
    "Gregorian:  " .. M.gregorian_string(abs),
    "ISO:        " .. safe(M.iso_string),
    "Day of Yr:  " .. safe(M.day_of_year_string),
    "Julian:     " .. safe(M.julian_string),
    "Astron. JD: " .. M.astro_string(abs) .. " (Julian date number at noon UTC)",
    "Hebrew:     " .. safe(M.hebrew_string) .. " (until sunset)",
    "Islamic:    " .. safe(M.islamic_string) .. " (until sunset)",
    "French:     " .. safe(M.french_string),
    "Bahá’í:     " .. safe(M.bahai_string) .. " (until sunset)",
    "Mayan:      " .. safe(M.mayan_string),
    "Coptic:     " .. safe(M.coptic_string),
    "Ethiopic:   " .. safe(M.ethiopic_string),
    "Persian:    " .. safe(M.persian_string),
    "Chinese:    " .. (safe(M.chinese_string) or ""),
  }
end

---------------------------------------------------------------------------
-- The three months around a date (calendar-get-month-range)
---------------------------------------------------------------------------

--- The first and last month of the three-month calendar window centred on
--- the month of ABS.
---@param abs integer
---@return integer m1, integer y1, integer m2, integer y2
function M.month_range(abs)
  local m, _, y = greg_from_abs(abs)
  local m1, y1 = astro.increment_month(m, y, -1)
  local m2, y2 = astro.increment_month(m, y, 1)
  return m1, y1, m2, y2
end

--- "from August to October, 2026" or "from December, 2026 to February, 2027".
local function range_title(m1, y1, m2, y2)
  if y1 == y2 then
    return string.format("from %s to %s, %d", MONTH_NAMES[m1], MONTH_NAMES[m2], y2)
  end
  return string.format("from %s, %d to %s, %d", MONTH_NAMES[m1], y1, MONTH_NAMES[m2], y2)
end

---------------------------------------------------------------------------
-- Phases of the moon (lunar.el)
---------------------------------------------------------------------------

M.phase_names = { "New Moon", "First Quarter Moon", "Full Moon", "Last Quarter Moon" } -- lunar-phase-names

--- lunar-check-for-eclipse
local function check_for_eclipse(moon_lat, phase)
  local node_dist = astro.emod(moon_lat, 180)
  node_dist = math.min(node_dist, 180 - node_dist)
  local kind = phase == 0 and "Solar" or phase == 2 and "Lunar" or nil
  if not kind then
    return ""
  elseif node_dist < 13.9 then
    return "** " .. kind .. " Eclipse **"
  elseif node_dist < 21.0 then
    return "** " .. kind .. " Eclipse possible **"
  end
  return ""
end

local ABS_1900 = abs_from_greg(1, 0.5, 1900)

---@class org.agenda.calendars.Phase
---@field abs integer local date
---@field time string local time ("10:28pm (EDT)")
---@field phase integer 0 new, 1 first quarter, 2 full, 3 last quarter
---@field eclipse string

--- lunar-phase: local date and time of lunar phase INDEX (lunation * 4 +
--- phase since 1900-01-01) in zone Z.
---@param z org.agenda.holidays.Zone
---@param index integer
---@return org.agenda.calendars.Phase
function M.lunar_phase(z, index)
  local sin_deg, cos_deg, emod = astro.sin_deg, astro.cos_deg, astro.emod
  local phase = index % 4
  local k = index / 4.0
  local time = k / 1236.85
  local date = ABS_1900
    + 0.75933
    + 29.53058868 * k
    + 0.0001178 * time * time
    + -0.000000155 * time * time * time
    + 0.00033 * sin_deg(166.56 + 132.87 * time + -0.009173 * time * time)
  local sun_anomaly =
    emod(359.2242 + 29.105356 * k + -0.0000333 * time * time + -0.00000347 * time * time * time, 360.0)
  local moon_anomaly =
    emod(306.0253 + 385.81691806 * k + 0.0107306 * time * time + 0.00001236 * time * time * time, 360.0)
  local moon_lat = emod(21.2964 + 390.67050646 * k + -0.0016528 * time * time + -0.00000239 * time * time * time, 360.0)
  local eclipse = check_for_eclipse(moon_lat, phase)
  local adjustment
  if phase == 0 or phase == 2 then
    adjustment = (0.1734 - 0.000393 * time) * sin_deg(sun_anomaly)
      + 0.0021 * sin_deg(2 * sun_anomaly)
      + -0.4068 * sin_deg(moon_anomaly)
      + 0.0161 * sin_deg(2 * moon_anomaly)
      + -0.0004 * sin_deg(3 * moon_anomaly)
      + 0.0104 * sin_deg(2 * moon_lat)
      + -0.0051 * sin_deg(sun_anomaly + moon_anomaly)
      + -0.0074 * sin_deg(sun_anomaly - moon_anomaly)
      + 0.0004 * sin_deg(2 * moon_lat + sun_anomaly)
      + -0.0004 * sin_deg(2 * moon_lat - sun_anomaly)
      + -0.0006 * sin_deg(2 * moon_lat + moon_anomaly)
      + 0.0010 * sin_deg(2 * moon_lat - moon_anomaly)
      + 0.0005 * sin_deg(2 * moon_anomaly + sun_anomaly)
  else
    adjustment = (0.1721 - 0.0004 * time) * sin_deg(sun_anomaly)
      + 0.0021 * sin_deg(2 * sun_anomaly)
      + -0.6280 * sin_deg(moon_anomaly)
      + 0.0089 * sin_deg(2 * moon_anomaly)
      + -0.0004 * sin_deg(3 * moon_anomaly)
      + 0.0079 * sin_deg(2 * moon_lat)
      + -0.0119 * sin_deg(sun_anomaly + moon_anomaly)
      + -0.0047 * sin_deg(sun_anomaly - moon_anomaly)
      + 0.0003 * sin_deg(2 * moon_lat + sun_anomaly)
      + -0.0004 * sin_deg(2 * moon_lat - sun_anomaly)
      + -0.0006 * sin_deg(2 * moon_lat + moon_anomaly)
      + 0.0021 * sin_deg(2 * moon_lat - moon_anomaly)
      + 0.0003 * sin_deg(2 * moon_anomaly + sun_anomaly)
      + 0.0004 * sin_deg(sun_anomaly - 2 * moon_anomaly)
      + -0.0003 * sin_deg(2 * sun_anomaly + moon_anomaly)
  end
  local adj = 0.0028 + -0.0004 * cos_deg(sun_anomaly) + 0.0003 * cos_deg(moon_anomaly)
  if phase == 1 then
    adjustment = adjustment + adj
  elseif phase == 2 then
    adjustment = adjustment - adj
  end
  date = date + adjustment
  local _, _, ey = greg_from_abs(astro.truncate(date))
  date = date + (z.tz - astro.ephemeris_correction(ey)) / 60.0 / 24.0
  local td = astro.truncate(date)
  local hours = 24 * (date - td)
  local gm, gd, gy = greg_from_abs(td)
  local am, ad, ay, atime, zone = astro.dst_adjust_time(z, gm, gd, gy, hours)
  return { abs = abs_from_greg(am, ad, ay), time = astro.time_string(atime, zone), phase = phase, eclipse = eclipse }
end

--- lunar-phase-list: the phases in MONTH/YEAR and the N following months.
---@param z org.agenda.holidays.Zone
---@param month integer
---@param year integer
---@param n? integer default 2
---@return org.agenda.calendars.Phase[]
function M.lunar_phase_list(z, month, year, n)
  n = n or 2
  -- lunar-index
  local index = 4 * astro.truncate(12.3685 * (year + astro.day_number(month, 1, year) / 366.0 + -1900))
  local em, ey = astro.increment_month(month, year, n + 1)
  local end_abs = abs_from_greg(em, 1, ey)
  local pm, py = astro.increment_month(month, year, -1)
  local start_abs = abs_from_greg(pm, astro.last_day_of_month(pm, py), py)
  local list = {}
  local p = M.lunar_phase(z, index)
  while p.abs < end_abs do
    if start_abs < p.abs then
      list[#list + 1] = p
    end
    index = index + 1
    p = M.lunar_phase(z, index)
  end
  return list
end

--- The title and lines of calendar-lunar-phases for the three months
--- around ABS.
---@param abs integer
---@param z? org.agenda.holidays.Zone default: the system zone
---@return string title, string[] lines
function M.phases_lines(abs, z)
  z = z or require("org.agenda.holidays.solar").system_zone()
  local m1, y1, m2, y2 = M.month_range(abs)
  local lines = {}
  for _, p in ipairs(M.lunar_phase_list(z, m1, y1, 2)) do
    lines[#lines + 1] = M.gregorian_string(p.abs)
      .. ": "
      .. M.phase_names[p.phase + 1]
      .. " "
      .. p.time
      .. (p.eclipse ~= "" and (" " .. p.eclipse) or "")
  end
  return "Phases of the Moon " .. range_title(m1, y1, m2, y2), lines
end

---------------------------------------------------------------------------
-- Sunrise and sunset (solar.el)
---------------------------------------------------------------------------

--- The default calendar-location-name: "40.7N, 74.0W".
---@param latitude number
---@param longitude number
---@return string
function M.location_name(latitude, longitude)
  return string.format(
    "%.1f%s, %.1f%s",
    math.abs(latitude),
    latitude > 0 and "N" or "S",
    math.abs(longitude),
    longitude > 0 and "E" or "W"
  )
end

--- solar-sunrise-sunset-string: "Sunrise 6:49am (EDT), sunset 6:44pm (EDT)
--- at 40.7N, 74.0W (11:54 hrs daylight)".
---@param abs integer
---@param latitude number
---@param longitude number
---@param opts? { zone?: org.agenda.holidays.Zone, location?: string|false } location false: no " at ..."
---@return string
function M.sunrise_sunset_string(abs, latitude, longitude, opts)
  opts = opts or {}
  local z = opts.zone or require("org.agenda.holidays.solar").system_zone()
  local m, d, y = greg_from_abs(abs)
  local rise, set, length, rise_zone, set_zone = astro.sunrise_sunset(z, latitude, longitude, m, d, y)
  local location = ""
  if opts.location ~= false then
    location = " at " .. (opts.location or M.location_name(latitude, longitude))
  end
  return string.format(
    "%s, %s%s (%d:%02d hrs daylight)",
    rise and ("Sunrise " .. astro.time_string(rise, rise_zone)) or "No sunrise",
    set and ("sunset " .. astro.time_string(set, set_zone)) or "no sunset",
    location,
    floor(length),
    floor(60 * (length - floor(length)))
  )
end

---------------------------------------------------------------------------
-- Holidays (calendar-list-holidays)
---------------------------------------------------------------------------

--- The title and lines of calendar-list-holidays for the three months
--- around ABS ("Monday, September 7, 2026: Labor Day").
---@param abs integer
---@param opts? table the `agenda.holidays` options
---@return string title, string[] lines
function M.holidays_lines(abs, opts)
  local holidays = require("org.agenda.holidays")
  local m1, y1, m2, y2 = M.month_range(abs)
  local from = abs_from_greg(m1, 1, y1) - M.EPOCH_ABS
  local to = abs_from_greg(m2, astro.last_day_of_month(m2, y2), y2) - M.EPOCH_ABS
  local days = {}
  local by_day = {}
  for y = y1, y2 do
    for day, names in pairs(holidays.year(y, opts)) do
      if day >= from and day <= to then
        days[#days + 1] = day
        by_day[day] = names
      end
    end
  end
  table.sort(days)
  local lines = {}
  for _, day in ipairs(days) do
    for _, name in ipairs(by_day[day]) do
      lines[#lines + 1] = M.gregorian_string(day + M.EPOCH_ABS) .. ": " .. name
    end
  end
  return "Notable Dates " .. range_title(m1, y1, m2, y2), lines
end

return M
