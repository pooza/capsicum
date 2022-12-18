import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

class InstanceForm extends StatelessWidget {
  final Logger logger = Logger(printer: PrettyPrinter(colors: false));
  final TextEditingController domainTextController = TextEditingController();

  InstanceForm({super.key});

  Future onChangeDomainText(String domain) async {
    logger.i(domain);
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: <Widget>[
            TextField(
              controller: domainTextController,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.all(6),
                border: OutlineInputBorder(),
                labelText: 'インスタンスのドメイン',
              ),
              onChanged: onChangeDomainText,
            ),
            Container(),
            Container(),
            Container(),
          ],
        ),
      ),
    );
  }
}
