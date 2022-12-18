import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:capsicum/widgets/instance_container/instance_container.dart';

import 'instance_form.dart';

class InstanceFormState extends State<InstanceForm> {
  final Logger logger = Logger(printer: PrettyPrinter(colors: false));
  final TextEditingController domainTextController = TextEditingController();
  final InstanceContainer instanceContainer = InstanceContainer();

  Future onChangeDomainText(String domain) async {
    logger.i('InstanceForm: $domain');
    setState(() {
      instanceContainer.domain = domain;
    });
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
            instanceContainer,
            Container(),
            Container(),
          ],
        ),
      ),
    );
  }
}
