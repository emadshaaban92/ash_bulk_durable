"""Writes the XLSX fixtures that test/sheet/read_test.exs reads.

Run from the repository root with openpyxl (csvkit installs it):

    python3 test/fixtures/make_workbooks.py

openpyxl cannot write the dropdown Excel saves for a list on another sheet
(an x14 data validation, in the sheet's extension list), so it is added to
the saved file by hand. Reading it, openpyxl warns that it drops it.
"""

import datetime
import zipfile

import openpyxl

PATH = "test/fixtures/workbook.xlsx"

DROPDOWN = (
    '<extLst><ext uri="{CCE6A557-97BC-4b89-ADB6-D9C93CAAB3DF}" '
    'xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">'
    '<x14:dataValidations count="1" '
    'xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">'
    '<x14:dataValidation type="list" allowBlank="1" showErrorMessage="1">'
    "<x14:formula1><xm:f>Lists!$A$1:$A$2</xm:f></x14:formula1>"
    "<xm:sqref>B2:B10</xm:sqref>"
    "</x14:dataValidation></x14:dataValidations></ext></extLst>"
)

workbook = openpyxl.Workbook()
sheet = workbook.active
sheet.title = "Shelves"
sheet.append(["code", "open", "note", "since", "rate", "checked"])
sheet.append(["S1", True, "True", datetime.date(2024, 3, 1), 0.15,
              datetime.datetime(2024, 3, 1, 9, 30)])
sheet.append(["S2", False, "no", datetime.date(2024, 12, 31), 1,
              datetime.datetime(2024, 12, 31, 23, 59, 5)])
sheet["D2"].number_format = "dd-mmm-yyyy"
sheet["D3"].number_format = "dd.mm.yyyy"
sheet["E2"].number_format = "0%"
sheet["E3"].number_format = "0.00%"
sheet["F2"].number_format = "dd/mm/yyyy hh:mm"
sheet["F3"].number_format = "[$-409]m/d/yy h:mm AM/PM;@"
lists = workbook.create_sheet("Lists")
lists.append(["yes"])
lists.append(["no"])
workbook.save(PATH)

with zipfile.ZipFile(PATH) as source:
    entries = [(entry, source.read(entry.filename)) for entry in source.infolist()]

with zipfile.ZipFile(PATH, "w", zipfile.ZIP_DEFLATED) as target:
    for entry, data in entries:
        if entry.filename == "xl/worksheets/sheet1.xml":
            data = data.replace(b"</worksheet>", DROPDOWN.encode() + b"</worksheet>")
        target.writestr(entry, data)
